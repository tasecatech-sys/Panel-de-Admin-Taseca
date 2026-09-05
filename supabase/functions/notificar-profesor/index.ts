// Edge Function: notificar-profesor
//
// Recibe los datos de una clase recién agendada y envía un correo al
// profesor a través de Resend (https://resend.com).
//
// Cómo desplegarla (sin necesitar la CLI de Supabase):
//   1. Entra a tu proyecto en supabase.com > Edge Functions > Deploy a new function.
//   2. Nómbrala "notificar-profesor" y pega el contenido de este archivo.
//   3. En Project Settings > Edge Functions > Secrets, agrega:
//        RESEND_API_KEY = tu api key de resend.com
//        RESEND_FROM    = el remitente verificado en Resend
//                         (mientras no verifiques un dominio propio,
//                         Resend solo deja enviar a TU correo de
//                         cuenta usando "onboarding@resend.dev" como
//                         remitente -- para notificar a cualquier
//                         profesor real necesitas verificar un
//                         dominio en resend.com/domains)
//   4. Copia la URL que te da Supabase (algo como
//      https://<project-ref>.supabase.co/functions/v1/notificar-profesor)
//      y pégala en agendar-clase.html, en la constante NOTIFY_FUNCTION_URL.
//
// Esta función acepta peticiones sin autenticar (para que la pueda
// llamar la página pública de agendamiento). Solo envía un correo con
// los datos que le llegan -- no lee ni escribe nada en la base de datos.

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'onboarding@resend.dev';

const PLAT_LABEL: Record<string, string> = { excel: 'Excel', powerbi: 'Power BI' };

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  }

  if (!RESEND_API_KEY) {
    return new Response(
      JSON.stringify({ ok: false, error: 'Falta configurar el secreto RESEND_API_KEY en Supabase.' }),
      { status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
    );
  }

  let body: {
    profesorEmail?: string;
    estudianteNombre?: string;
    estudianteDocumento?: string;
    plataforma?: string;
    fecha?: string;
    hora?: string;
  };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: 'Body inválido' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const { profesorEmail, estudianteNombre, estudianteDocumento, plataforma, fecha, hora } = body;

  if (!profesorEmail) {
    return new Response(JSON.stringify({ ok: false, error: 'Falta el correo del profesor.' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const platLabel = PLAT_LABEL[plataforma ?? ''] ?? plataforma ?? '';
  const asunto = `Nueva clase agendada: ${platLabel} · ${fecha} ${hora}`;
  const html = `
    <p>Se agendó una nueva clase:</p>
    <ul>
      <li><b>Estudiante:</b> ${estudianteNombre ?? ''} (CC ${estudianteDocumento ?? ''})</li>
      <li><b>Plataforma:</b> ${platLabel}</li>
      <li><b>Fecha:</b> ${fecha ?? ''}</li>
      <li><b>Hora:</b> ${hora ?? ''}</li>
    </ul>
  `;

  const resendRes = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: RESEND_FROM,
      to: [profesorEmail],
      subject: asunto,
      html,
    }),
  });

  if (!resendRes.ok) {
    const detalle = await resendRes.text();
    return new Response(JSON.stringify({ ok: false, error: 'Resend rechazó el envío', detalle }), {
      status: 502,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
});
