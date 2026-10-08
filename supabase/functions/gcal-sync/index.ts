// Edge Function: gcal-sync
//
// Procesa la cola "gcal_sync" (ver supabase_gcal_sync.sql) y le pide al
// Google Apps Script de Taseca crear / actualizar / cancelar el evento
// de Google Calendar de cada cita.
//
// La llaman:
//   · los triggers de "horarios" y "agenda" (vía pg_net) apenas cambia
//     una cita  → { modo: 'procesar', origen, registro_id }
//   · pg_cron cada 10 min / cada hora → { modo: 'procesar' } (toda la cola)
//   · tú, para probar la conexión con Google → { modo: 'ping' }
//
// No la llama nunca el navegador. Se protege con el encabezado
// "x-sync-secret" (secreto compartido guardado en Supabase Vault y en
// los secretos de esta función). Desplegarla con "Verify JWT" APAGADO.
//
// Secretos (Project Settings > Edge Functions > Secrets):
//   GCAL_SYNC_SECRET   = secreto largo aleatorio (el mismo que en Vault)
//   APPS_SCRIPT_URL    = URL /exec de la Web App de Google Apps Script
//   APPS_SCRIPT_TOKEN  = el TOKEN de las propiedades del Apps Script
//   PANEL_URL          = (opcional) https://panel-de-admin-taseca.vercel.app
//   GCAL_INVITAR_PROFESOR / GCAL_INVITAR_ESTUDIANTE = (opcional) 'true'
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los pone Supabase solo.

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SYNC_SECRET = Deno.env.get('GCAL_SYNC_SECRET') ?? '';
const APPS_SCRIPT_URL = Deno.env.get('APPS_SCRIPT_URL') ?? '';
const APPS_SCRIPT_TOKEN = Deno.env.get('APPS_SCRIPT_TOKEN') ?? '';
const PANEL_URL = Deno.env.get('PANEL_URL') ?? 'https://panel-de-admin-taseca.vercel.app';
const INVITAR_PROFESOR = (Deno.env.get('GCAL_INVITAR_PROFESOR') ?? '') === 'true';
const INVITAR_ESTUDIANTE = (Deno.env.get('GCAL_INVITAR_ESTUDIANTE') ?? '') === 'true';

const LOTE = 10;                  // citas por vuelta
const PRESUPUESTO_MS = 100_000;   // margen bajo el límite de la Edge Function
const TIMEOUT_APPS_SCRIPT_MS = 30_000;

// deno-lint-ignore no-explicit-any
let _sb: any = null;
const db = () => (_sb ??= createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } }));

type FilaSync = {
  origen: 'horarios' | 'agenda';
  registro_id: string;
  gcal_event_id: string | null;
  version: number;
};

export type Cita = {
  origen: 'horarios' | 'agenda';
  registro_id: string;
  activa: boolean;
  fecha: string;          // YYYY-MM-DD
  hora: string | null;    // 'HH:MM' (o 'HH:MM:SS', o '3:00 PM')
  duracion_min: number | null;
  tipo: string | null;
  plataforma: string | null;
  modalidad: string | null;
  profesor: string | null;
  notas: string | null;
  estado_origen: string | null;
  cliente_nombre: string | null;
  cliente_email: string | null;
  cliente_telefono: string | null;
  cliente_documento: string | null;
};

type RespuestaGas = {
  ok: boolean;
  accion?: string;
  eventId?: string | null;
  htmlLink?: string | null;
  meetUrl?: string | null;
  codigo?: string;
  error?: string;
};

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });

function igualSeguro(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/* ---------------- Construcción del evento ---------------- */

const PLAT: Record<string, string> = { excel: 'Excel', powerbi: 'Power BI' };

/** Convierte '19:00', '19:00:00', '7:00 PM' → { h, m }. */
export function parseHora(hora: string | null): { h: number; m: number } | null {
  if (!hora) return null;
  const t = hora.trim().toUpperCase();
  const r = t.match(/^(\d{1,2}):(\d{2})(?::\d{2})?\s*(AM|PM|A\.?\s?M\.?|P\.?\s?M\.?)?$/);
  if (!r) return null;
  let h = Number(r[1]);
  const m = Number(r[2]);
  const ampm = r[3]?.replace(/[\s.]/g, '');
  if (ampm === 'PM' && h < 12) h += 12;
  if (ampm === 'AM' && h === 12) h = 0;
  if (h > 23 || m > 59) return null;
  return { h, m };
}

const dos = (n: number) => String(n).padStart(2, '0');

/** Suma minutos a una fecha/hora "local" (sin zona) y devuelve 'YYYY-MM-DDTHH:MM'. */
export function sumarMinutos(fecha: string, h: number, m: number, minutos: number): string {
  const [Y, M, D] = fecha.split('-').map(Number);
  const d = new Date(Date.UTC(Y, M - 1, D, h, m) + minutos * 60_000);
  return `${d.getUTCFullYear()}-${dos(d.getUTCMonth() + 1)}-${dos(d.getUTCDate())}T${dos(d.getUTCHours())}:${dos(d.getUTCMinutes())}`;
}

export function construirEvento(c: Cita, panelUrl = PANEL_URL) {
  const fecha = String(c.fecha ?? '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) throw new Error(`Fecha inválida en la cita: "${c.fecha}"`);
  const hm = parseHora(c.hora);
  if (!hm) throw new Error(`Hora inválida en la cita: "${c.hora}"`);
  const dur = c.duracion_min && c.duracion_min > 0 && c.duracion_min <= 12 * 60 ? c.duracion_min : 60;

  const tipo = (c.tipo ?? '').trim() || 'Clase';
  const nombre = (c.cliente_nombre ?? '').trim();
  const titulo = nombre ? `${tipo} · ${nombre}` : tipo;
  const virtual = (c.modalidad ?? '').trim().toLowerCase() === 'virtual';

  const lineas = [
    nombre && `Estudiante/cliente: ${nombre}${c.cliente_documento ? ` (CC ${c.cliente_documento})` : ''}`,
    c.cliente_email && `Correo: ${c.cliente_email}`,
    c.cliente_telefono && `Teléfono: ${c.cliente_telefono}`,
    c.plataforma && `Plataforma: ${PLAT[c.plataforma] ?? c.plataforma}`,
    c.modalidad && `Modalidad: ${c.modalidad}`,
    `Duración: ${dur} min`,
    c.profesor && `Profesor: ${c.profesor}`,
    c.notas && `Notas: ${c.notas}`,
    '—',
    `Panel: ${panelUrl}`,
    `Ref. Supabase: ${c.origen}/${c.registro_id}`,
    'Evento creado automáticamente por el panel de Taseca. Los cambios se hacen en el panel, no aquí.',
  ].filter(Boolean) as string[];

  const invitados: string[] = [];
  if (INVITAR_PROFESOR && c.profesor) invitados.push(c.profesor);
  if (INVITAR_ESTUDIANTE && c.cliente_email) invitados.push(c.cliente_email);

  return {
    titulo,
    descripcion: lineas.join('\n').replace('\n—\n', '\n\n'),
    ubicacion: virtual ? 'Google Meet' : (c.modalidad ?? ''),
    inicio: `${fecha}T${dos(hm.h)}:${dos(hm.m)}`,
    fin: sumarMinutos(fecha, hm.h, hm.m, dur),
    conMeet: virtual,
    invitados,
  };
}

/* ---------------- Llamada a Google Apps Script ---------------- */

async function llamarAppsScript(payload: Record<string, unknown>): Promise<RespuestaGas> {
  if (!APPS_SCRIPT_URL || !APPS_SCRIPT_TOKEN) {
    return { ok: false, codigo: 'CONFIG', error: 'Faltan los secretos APPS_SCRIPT_URL / APPS_SCRIPT_TOKEN.' };
  }
  let res: Response;
  try {
    // Apps Script responde con un 302 a googleusercontent.com; fetch lo sigue solo.
    res = await fetch(APPS_SCRIPT_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...payload, token: APPS_SCRIPT_TOKEN }),
      redirect: 'follow',
      signal: AbortSignal.timeout(TIMEOUT_APPS_SCRIPT_MS),
    });
  } catch (err) {
    return { ok: false, codigo: 'RED', error: `No se pudo contactar a Apps Script: ${(err as Error).message}` };
  }
  const texto = await res.text();
  try {
    return JSON.parse(texto) as RespuestaGas;
  } catch {
    // Típico cuando el despliegue no es "Cualquier persona" (devuelve HTML de login).
    return { ok: false, codigo: 'RESPUESTA_NO_JSON', error: `Apps Script respondió HTTP ${res.status} sin JSON: ${texto.slice(0, 200)}` };
  }
}

/* ---------------- Procesamiento de la cola ---------------- */

async function reclamar(limite: number, origen?: string, registroId?: string): Promise<FilaSync[]> {
  const { data, error } = await db().rpc('gcal_sync_reclamar', {
    p_limite: limite,
    p_origen: origen ?? null,
    p_registro_id: registroId ?? null,
  });
  if (error) throw new Error(`gcal_sync_reclamar: ${error.message}`);
  return (data ?? []) as FilaSync[];
}

async function finalizar(f: FilaSync, ok: boolean, extra: Record<string, unknown>) {
  const { error } = await db().rpc('gcal_sync_finalizar', {
    p_origen: f.origen,
    p_registro_id: f.registro_id,
    p_version: f.version,
    p_ok: ok,
    ...extra,
  });
  if (error) console.error('gcal_sync_finalizar', f.origen, f.registro_id, error.message);
}

async function procesarFila(f: FilaSync) {
  const ref = `${f.origen}:${f.registro_id}`;
  try {
    const { data: cita, error } = await db()
      .from('gcal_citas')
      .select('*')
      .eq('origen', f.origen)
      .eq('registro_id', f.registro_id)
      .maybeSingle();
    if (error) throw new Error(`Leyendo la cita: ${error.message}`);

    // Se decide SIEMPRE con el estado actual de la cita (no con lo que
    // pasó antes): si cambió 3 veces seguidas, basta con la última.
    let r: RespuestaGas;
    let estadoFinal: 'sincronizado' | 'cancelado';
    if (cita && (cita as Cita).activa) {
      const evento = construirEvento(cita as Cita);
      r = await llamarAppsScript({ accion: 'upsert', ref, eventId: f.gcal_event_id, evento });
      estadoFinal = 'sincronizado';
    } else {
      r = await llamarAppsScript({ accion: 'cancelar', ref, eventId: f.gcal_event_id });
      estadoFinal = 'cancelado';
    }

    if (!r.ok) throw new Error(`[${r.codigo ?? 'ERROR'}] ${r.error ?? 'Apps Script devolvió ok:false'}`);

    await finalizar(f, true, {
      p_estado: estadoFinal,
      p_accion: r.accion ?? null,
      p_event_id: r.eventId ?? null,
      p_html_link: r.htmlLink ?? null,
      p_meet_url: r.meetUrl ?? null,
    });
    return { ref, ok: true, accion: r.accion, eventId: r.eventId };
  } catch (err) {
    const msg = (err as Error).message ?? String(err);
    console.error('gcal-sync', ref, msg);
    await finalizar(f, false, { p_error: msg });
    return { ref, ok: false, error: msg };
  }
}

export async function handler(req: Request): Promise<Response> {
  if (req.method !== 'POST') return json({ ok: false, error: 'Method not allowed' }, 405);
  if (!SYNC_SECRET) return json({ ok: false, error: 'Falta el secreto GCAL_SYNC_SECRET.' }, 500);
  if (!igualSeguro(req.headers.get('x-sync-secret') ?? '', SYNC_SECRET)) {
    return json({ ok: false, error: 'No autorizado' }, 401);
  }

  let body: { modo?: string; origen?: string; registro_id?: string } = {};
  try { body = await req.json(); } catch { /* cuerpo vacío = procesar toda la cola */ }

  if (body.modo === 'ping') {
    const r = await llamarAppsScript({ accion: 'ping' });
    return json({ ok: r.ok, appsScript: r }, r.ok ? 200 : 502);
  }

  const inicio = Date.now();
  const resultados: unknown[] = [];
  try {
    if (body.origen && body.registro_id) {
      // Disparo en tiempo real de UNA cita. Hasta 3 vueltas por si la
      // cita volvió a cambiar mientras se sincronizaba.
      for (let vuelta = 0; vuelta < 3; vuelta++) {
        const filas = await reclamar(1, body.origen, body.registro_id);
        if (!filas.length) break;
        resultados.push(await procesarFila(filas[0]));
      }
    } else {
      while (Date.now() - inicio < PRESUPUESTO_MS) {
        const filas = await reclamar(LOTE);
        if (!filas.length) break;
        for (const f of filas) resultados.push(await procesarFila(f));
      }
    }
  } catch (err) {
    return json({ ok: false, error: (err as Error).message, resultados }, 500);
  }

  return json({ ok: true, procesadas: resultados.length, resultados });
}

// En pruebas unitarias (GCAL_SYNC_TEST=1) solo se importan las funciones.
if (!Deno.env.get('GCAL_SYNC_TEST')) Deno.serve(handler);
