// Pruebas unitarias de la Edge Function gcal-sync (construcción del evento).
// Ejecutar:  GCAL_SYNC_TEST=1 deno test --allow-env --allow-net tests/gcal_sync_edge_test.ts
import { deepStrictEqual as assertEquals, throws as assertThrows } from 'node:assert';
import { construirEvento, parseHora, sumarMinutos, type Cita } from '../supabase/functions/gcal-sync/index.ts';

const base: Cita = {
  origen: 'horarios', registro_id: '11111111-1111-4111-8111-111111111111', activa: true,
  fecha: '2026-10-15', hora: '19:00', duracion_min: 60, tipo: 'Clase Power BI', plataforma: 'powerbi',
  modalidad: 'Virtual', profesor: 'profe@taseca.tech', notas: null, estado_origen: 'reservado',
  cliente_nombre: 'Juan Pérez', cliente_email: 'juan@example.com', cliente_telefono: '3001234567', cliente_documento: '123',
};

Deno.test('parseHora acepta formatos reales', () => {
  assertEquals(parseHora('19:00'), { h: 19, m: 0 });
  assertEquals(parseHora('07:30:00'), { h: 7, m: 30 });
  assertEquals(parseHora('7:00 PM'), { h: 19, m: 0 });
  assertEquals(parseHora('12:15 a. m.'), { h: 0, m: 15 });
  assertEquals(parseHora('25:00'), null);
  assertEquals(parseHora(''), null);
});

Deno.test('sumarMinutos cruza medianoche y fin de mes', () => {
  assertEquals(sumarMinutos('2026-10-31', 23, 30, 60), '2026-11-01T00:30');
  assertEquals(sumarMinutos('2026-10-15', 19, 0, 45), '2026-10-15T19:45');
});

Deno.test('cita de horarios → evento 19:00-20:00 Bogotá con Meet', () => {
  const ev = construirEvento(base, 'https://panel');
  assertEquals(ev.titulo, 'Clase Power BI · Juan Pérez');
  assertEquals(ev.inicio, '2026-10-15T19:00');
  assertEquals(ev.fin, '2026-10-15T20:00');
  assertEquals(ev.conMeet, true);
  assertEquals(ev.invitados, []);
  assertEquals(ev.descripcion.includes('Ref. Supabase: horarios/1111'), true);
  assertEquals(ev.descripcion.includes('\n\n'), true);
});

Deno.test('agenda presencial 90 min sin estudiante → sin Meet, título solo tipo', () => {
  const ev = construirEvento({ ...base, origen: 'agenda', tipo: 'Reunión', modalidad: 'Presencial', duracion_min: 90, cliente_nombre: null, cliente_documento: null });
  assertEquals(ev.titulo, 'Reunión');
  assertEquals(ev.fin, '2026-10-15T20:30');
  assertEquals(ev.conMeet, false);
  assertEquals(ev.descripcion.includes('\n\n\n'), false);
});

Deno.test('duración vacía o absurda → 60 min', () => {
  assertEquals(construirEvento({ ...base, duracion_min: null }).fin, '2026-10-15T20:00');
  assertEquals(construirEvento({ ...base, duracion_min: 5000 }).fin, '2026-10-15T20:00');
});

Deno.test('datos inválidos lanzan error (quedan en estado error, no crean basura)', () => {
  assertThrows(() => construirEvento({ ...base, hora: 'mañana' }));
  assertThrows(() => construirEvento({ ...base, fecha: '' }));
});
