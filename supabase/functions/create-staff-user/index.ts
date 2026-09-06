// Edge Function: create-staff-user
//
// Crea una cuenta de acceso al panel (Supabase Auth) para un nuevo
// miembro del equipo, y su fila correspondiente en "staff_usuarios".
// Solo puede ejecutarla alguien que YA es administrador activo en el
// panel -- esta función verifica eso antes de crear nada, para que
// nadie pueda crearse a sí mismo una cuenta de administrador.
//
// Cómo desplegarla (sin necesitar la CLI de Supabase):
//   1. Entra a tu proyecto en supabase.com > Edge Functions > Deploy a new function.
//   2. Nómbrala "create-staff-user" y pega el contenido de este archivo.
//   3. No necesitas configurar ningún secreto: SUPABASE_URL y
//      SUPABASE_SERVICE_ROLE_KEY ya están disponibles automáticamente
//      dentro de toda Edge Function de tu proyecto.
//   4. Deploy. admin-taseca.html ya está armado para llamarla en
//      Configuración > Gestión de usuarios > Crear nuevo usuario.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

const ROLES_VALIDOS = ['admin', 'profesor', 'contador'];

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const token = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
  if (!token) return json({ error: 'No autenticado.' }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Verifica que quien llama es un administrador activo antes de crear nada.
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) return json({ error: 'Sesión inválida o expirada.' }, 401);

  const callerEmail = (userData.user.email || '').toLowerCase();
  const { data: caller, error: callerErr } = await admin
    .from('staff_usuarios')
    .select('rol, activo')
    .eq('email', callerEmail)
    .maybeSingle();

  if (callerErr) return json({ error: 'No se pudo verificar tu rol: ' + callerErr.message }, 500);
  if (!caller || caller.rol !== 'admin' || !caller.activo) {
    return json({ error: 'Solo un administrador activo puede crear usuarios.' }, 403);
  }

  let body: { nombre?: string; email?: string; password?: string; rol?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Body inválido.' }, 400);
  }

  const nombre = (body.nombre || '').trim();
  const email = (body.email || '').trim().toLowerCase();
  const password = body.password || '';
  const rol = body.rol || '';

  if (!email || !password) return json({ error: 'Correo y contraseña son obligatorios.' }, 400);
  if (password.length < 8) return json({ error: 'La contraseña debe tener al menos 8 caracteres.' }, 400);
  if (!ROLES_VALIDOS.includes(rol)) return json({ error: 'Rol inválido.' }, 400);

  const { error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (createErr) return json({ error: createErr.message }, 400);

  const { error: upsertErr } = await admin
    .from('staff_usuarios')
    .upsert({ email, nombre: nombre || email, rol, activo: true }, { onConflict: 'email' });
  if (upsertErr) {
    return json(
      { error: 'El usuario se creó en Supabase Auth, pero no se pudo guardar en staff_usuarios: ' + upsertErr.message },
      500,
    );
  }

  return json({ ok: true });
});
