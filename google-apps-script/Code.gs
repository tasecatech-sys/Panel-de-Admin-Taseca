/**
 * ============================================================
 * Taseca · Puente Supabase → Google Calendar (Google Apps Script)
 * ============================================================
 * Web App que recibe peticiones de la Edge Function "gcal-sync" de
 * Supabase y crea / actualiza / cancela eventos en el Google Calendar
 * de Taseca, con recordatorios y (opcional) enlace de Google Meet.
 *
 * Seguridad:
 *  - Las credenciales de Google NUNCA salen de aquí: el script corre
 *    como la cuenta de Taseca ("Ejecutar como: Yo").
 *  - Cada petición debe traer el TOKEN guardado en Propiedades del
 *    script. Solo la Edge Function lo conoce (no está en el navegador).
 *
 * Anti-duplicados:
 *  - Cada evento lleva una etiqueta oculta tasecaRef = "<origen>:<uuid>".
 *    Antes de crear, se busca por esa etiqueta: aunque Supabase haya
 *    perdido el event_id, nunca se crea un segundo evento.
 *  - LockService serializa las peticiones simultáneas.
 *
 * Requiere: Servicios > "Google Calendar API" (Advanced Service, v3)
 * habilitado con el identificador "Calendar". Ver docs/GCAL_SYNC.md.
 * ============================================================
 */

/** ---------- CONFIGURACIÓN CENTRALIZADA (edítala aquí) ---------- */
const CONFIG = {
  // 'primary' = calendario principal de la cuenta que despliega el script.
  // Para un calendario secundario usa su ID (Configuración del calendario >
  // "ID del calendario", algo como abc123@group.calendar.google.com).
  CALENDAR_ID: 'primary',

  TIMEZONE: 'America/Bogota',

  // Recordatorios de cada evento (máximo 5). method: 'popup' (notificación
  // en celular/navegador) o 'email'. minutes: minutos antes de la clase.
  RECORDATORIOS: [
    { method: 'popup', minutes: 24 * 60 }, // 24 horas antes
    { method: 'popup', minutes: 60 },      // 1 hora antes
    { method: 'popup', minutes: 15 },      // 15 minutos antes
  ],

  // Interruptor general de Google Meet. La Edge Function decide por cita
  // (solo modalidad Virtual); si esto es false, nunca se crea Meet.
  MEET_HABILITADO: true,

  // Color de los eventos por origen (IDs de color de Google Calendar 1-11).
  // null = color por defecto del calendario.
  COLOR_POR_ORIGEN: { horarios: '9', agenda: '5' },

  // Tiempo máximo esperando el candado (ms).
  LOCK_MS: 25000,
};
/** -------------------------------------------------------------- */

const REF_REGEX = /^(horarios|agenda):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATETIME_REGEX = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/;

/** Punto de entrada de la Web App. */
function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) {
      return respuesta_({ ok: false, codigo: 'SIN_CUERPO', error: 'Petición sin cuerpo JSON.' });
    }
    let body;
    try {
      body = JSON.parse(e.postData.contents);
    } catch (err) {
      return respuesta_({ ok: false, codigo: 'JSON_INVALIDO', error: 'El cuerpo no es JSON válido.' });
    }

    if (!tokenValido_(body.token)) {
      return respuesta_({ ok: false, codigo: 'NO_AUTORIZADO', error: 'Token inválido.' });
    }

    switch (body.accion) {
      case 'ping':
        return respuesta_({ ok: true, accion: 'pong', calendario: CONFIG.CALENDAR_ID, zona: CONFIG.TIMEZONE });
      case 'upsert':
        return respuesta_(upsertEvento_(body));
      case 'cancelar':
        return respuesta_(cancelarEvento_(body));
      case 'buscar':
        return respuesta_(buscarPorRef_(body));
      default:
        return respuesta_({ ok: false, codigo: 'ACCION_INVALIDA', error: 'Acción no soportada: ' + body.accion });
    }
  } catch (err) {
    console.error(err && err.stack ? err.stack : err);
    return respuesta_({ ok: false, codigo: 'ERROR_INTERNO', error: String(err && err.message ? err.message : err) });
  }
}

/** GET no expone nada: solo confirma que el despliegue está vivo. */
function doGet() {
  return respuesta_({ ok: true, servicio: 'taseca-gcal-sync', mensaje: 'Usa POST.' });
}

/* ================= ACCIONES ================= */

function upsertEvento_(body) {
  validarRef_(body.ref);
  const ev = validarEvento_(body.evento);
  const quiereMeet = CONFIG.MEET_HABILITADO && ev.conMeet === true;
  const invitados = (ev.invitados || []).filter(esEmail_);
  const sendUpdates = invitados.length ? 'all' : 'none';

  return conCandado_(function () {
    const recurso = construirRecurso_(body.ref, ev, invitados);
    const hash = recurso.extendedProperties.private.tasecaHash;
    let existente = buscarEvento_(body.eventId, body.ref);

    if (existente) {
      const tieneMeet = !!linkMeet_(existente);
      const hashActual = existente.extendedProperties && existente.extendedProperties.private
        ? existente.extendedProperties.private.tasecaHash : null;

      if (hashActual === hash && (tieneMeet || !quiereMeet)) {
        return ok_('sin_cambios', existente);
      }
      if (quiereMeet && !tieneMeet) recurso.conferenceData = solicitudMeet_();
      const actualizado = Calendar.Events.patch(recurso, CONFIG.CALENDAR_ID, existente.id, {
        conferenceDataVersion: 1,
        sendUpdates: sendUpdates,
      });
      return ok_('actualizado', actualizado);
    }

    if (quiereMeet) recurso.conferenceData = solicitudMeet_();
    const creado = Calendar.Events.insert(recurso, CONFIG.CALENDAR_ID, {
      conferenceDataVersion: 1,
      sendUpdates: sendUpdates,
    });
    return ok_('creado', creado);
  });
}

function cancelarEvento_(body) {
  validarRef_(body.ref);
  return conCandado_(function () {
    const existente = buscarEvento_(body.eventId, body.ref);
    if (!existente) {
      return { ok: true, accion: 'no_existia', eventId: body.eventId || null };
    }
    // Se ELIMINA (queda en estado "cancelled" en Google): así no suena
    // ningún recordatorio de una clase que ya no existe. El historial
    // queda en Supabase (gcal_sync) por si se necesita.
    const tieneInvitados = (existente.attendees || []).length > 0;
    Calendar.Events.remove(CONFIG.CALENDAR_ID, existente.id, { sendUpdates: tieneInvitados ? 'all' : 'none' });
    return { ok: true, accion: 'cancelado', eventId: existente.id };
  });
}

function buscarPorRef_(body) {
  validarRef_(body.ref);
  const ev = buscarEvento_(body.eventId, body.ref);
  return ev ? ok_('encontrado', ev) : { ok: true, accion: 'no_existe', eventId: null };
}

/* ================= AUXILIARES ================= */

/**
 * Busca el evento de una cita: primero por eventId; si no existe, está
 * cancelado o pertenece a otra cita, busca por la etiqueta tasecaRef.
 * Si encuentra duplicados heredados, conserva uno y elimina el resto.
 */
function buscarEvento_(eventId, ref) {
  if (eventId) {
    try {
      const ev = Calendar.Events.get(CONFIG.CALENDAR_ID, eventId);
      const refEv = ev && ev.extendedProperties && ev.extendedProperties.private
        ? ev.extendedProperties.private.tasecaRef : null;
      if (ev && ev.status !== 'cancelled' && (!refEv || refEv === ref)) return ev;
    } catch (err) {
      if (!esNoEncontrado_(err)) throw err;
    }
  }

  const res = Calendar.Events.list(CONFIG.CALENDAR_ID, {
    privateExtendedProperty: 'tasecaRef=' + ref,
    showDeleted: false,
    maxResults: 10,
  });
  const items = (res.items || []).filter(function (i) { return i.status !== 'cancelled'; });
  if (items.length > 1) {
    items.slice(1).forEach(function (dup) {
      try { Calendar.Events.remove(CONFIG.CALENDAR_ID, dup.id, { sendUpdates: 'none' }); }
      catch (err) { console.warn('No se pudo borrar duplicado ' + dup.id + ': ' + err); }
    });
  }
  return items[0] || null;
}

function construirRecurso_(ref, ev, invitados) {
  const origen = ref.split(':')[0];
  const recordatorios = CONFIG.RECORDATORIOS.slice(0, 5).map(function (r) {
    return { method: r.method, minutes: Number(r.minutes) };
  });

  const base = {
    summary: ev.titulo,
    description: ev.descripcion || '',
    location: ev.ubicacion || '',
    start: { dateTime: normalizarFecha_(ev.inicio), timeZone: CONFIG.TIMEZONE },
    end: { dateTime: normalizarFecha_(ev.fin), timeZone: CONFIG.TIMEZONE },
    reminders: { useDefault: false, overrides: recordatorios },
    attendees: invitados.map(function (m) { return { email: m }; }),
    status: 'confirmed',
  };
  const color = CONFIG.COLOR_POR_ORIGEN[origen];
  if (color) base.colorId = color;

  // La huella incluye la config de recordatorios: si la cambias, la
  // próxima verificación actualiza los eventos existentes.
  const hash = huella_(JSON.stringify(base));
  base.extendedProperties = { private: { tasecaRef: ref, tasecaHash: hash, tasecaOrigen: origen } };
  return base;
}

function solicitudMeet_() {
  return { createRequest: { requestId: Utilities.getUuid(), conferenceSolutionKey: { type: 'hangoutsMeet' } } };
}

function linkMeet_(ev) {
  if (ev.hangoutLink) return ev.hangoutLink;
  const eps = ev.conferenceData && ev.conferenceData.entryPoints;
  if (eps) {
    const video = eps.filter(function (p) { return p.entryPointType === 'video'; })[0];
    if (video) return video.uri;
  }
  return null;
}

function ok_(accion, ev) {
  return { ok: true, accion: accion, eventId: ev.id, htmlLink: ev.htmlLink || null, meetUrl: linkMeet_(ev) };
}

function validarRef_(ref) {
  if (typeof ref !== 'string' || !REF_REGEX.test(ref)) {
    throw new Error('ref inválido (se espera "horarios:<uuid>" o "agenda:<uuid>").');
  }
}

function validarEvento_(ev) {
  if (!ev || typeof ev !== 'object') throw new Error('Falta "evento".');
  if (!ev.titulo || typeof ev.titulo !== 'string') throw new Error('evento.titulo es obligatorio.');
  if (!DATETIME_REGEX.test(ev.inicio || '')) throw new Error('evento.inicio inválido (YYYY-MM-DDTHH:MM).');
  if (!DATETIME_REGEX.test(ev.fin || '')) throw new Error('evento.fin inválido (YYYY-MM-DDTHH:MM).');
  if (normalizarFecha_(ev.fin) <= normalizarFecha_(ev.inicio)) throw new Error('evento.fin debe ser posterior a evento.inicio.');
  ev.titulo = ev.titulo.slice(0, 250);
  if (ev.descripcion) ev.descripcion = String(ev.descripcion).slice(0, 4000);
  return ev;
}

function normalizarFecha_(s) {
  return s.length === 16 ? s + ':00' : s;
}

function esEmail_(s) {
  return typeof s === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
}

function esNoEncontrado_(err) {
  const m = String(err && err.message ? err.message : err);
  return /not found|404|410|deleted/i.test(m);
}

function tokenValido_(token) {
  const esperado = PropertiesService.getScriptProperties().getProperty('TOKEN');
  if (!esperado || esperado.length < 24) {
    throw new Error('Falta configurar la propiedad del script TOKEN (mínimo 24 caracteres).');
  }
  if (typeof token !== 'string' || token.length !== esperado.length) return false;
  let diff = 0;
  for (let i = 0; i < token.length; i++) diff |= token.charCodeAt(i) ^ esperado.charCodeAt(i);
  return diff === 0;
}

function conCandado_(fn) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(CONFIG.LOCK_MS)) {
    return { ok: false, codigo: 'OCUPADO', error: 'Otro proceso está sincronizando; se reintentará.' };
  }
  try {
    return fn();
  } finally {
    lock.releaseLock();
  }
}

function huella_(texto) {
  const bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, texto, Utilities.Charset.UTF_8);
  return bytes.map(function (b) { return ('0' + (b & 0xff).toString(16)).slice(-2); }).join('').slice(0, 32);
}

function respuesta_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

/* ================= UTILIDADES MANUALES (ejecutar desde el editor) ================= */

/**
 * Genera un TOKEN aleatorio y lo guarda en Propiedades del script.
 * Ejecútala UNA vez; copia el valor del registro (Ver > Registros) y
 * pégalo como secreto APPS_SCRIPT_TOKEN en Supabase.
 */
function generarToken() {
  const token = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
  PropertiesService.getScriptProperties().setProperty('TOKEN', token);
  console.log('TOKEN generado (cópialo a Supabase como APPS_SCRIPT_TOKEN): ' + token);
}

/**
 * Prueba de punta a punta desde el editor (también sirve para otorgar
 * los permisos de Calendar la primera vez). Crea un evento de prueba
 * para mañana, lo actualiza, comprueba que no se duplica y lo cancela.
 */
function probarIntegracion() {
  const ref = 'agenda:00000000-0000-4000-8000-000000000001';
  const manana = Utilities.formatDate(new Date(Date.now() + 864e5), CONFIG.TIMEZONE, 'yyyy-MM-dd');
  const evento = {
    titulo: 'PRUEBA Taseca · borrar',
    descripcion: 'Evento de prueba de la integración.',
    inicio: manana + 'T19:00',
    fin: manana + 'T20:00',
    conMeet: true,
  };
  const r1 = upsertEvento_({ ref: ref, evento: evento });
  console.log('1) crear: ' + JSON.stringify(r1));
  const r2 = upsertEvento_({ ref: ref, evento: evento }); // sin eventId → debe encontrarlo por ref
  console.log('2) repetir (debe ser sin_cambios, mismo id): ' + JSON.stringify(r2));
  evento.fin = manana + 'T20:30';
  const r3 = upsertEvento_({ ref: ref, eventId: r1.eventId, evento: evento });
  console.log('3) actualizar: ' + JSON.stringify(r3));
  const r4 = cancelarEvento_({ ref: ref, eventId: r1.eventId });
  console.log('4) cancelar: ' + JSON.stringify(r4));
  const r5 = cancelarEvento_({ ref: ref, eventId: r1.eventId });
  console.log('5) cancelar otra vez (debe ser no_existia): ' + JSON.stringify(r5));
}
