-- ============================================================
-- Taseca · Pruebas de la sincronización con Google Calendar (capa BD)
-- ============================================================
-- Se puede correr en Supabase > SQL Editor SIN riesgo: todo va dentro
-- de una transacción que termina en ROLLBACK, así que no deja datos
-- de prueba ni envía nada a Google (las llamadas de pg_net también se
-- descartan con el rollback).
--
-- Si todo sale bien, verás al final:  NOTICE: ✅ TODAS LAS PRUEBAS PASARON
-- Si una falla, verás "assert failed" con el número de la prueba.
--
-- Las pruebas de la parte Google (Apps Script) están en
-- docs/GCAL_SYNC.md, sección "Pruebas de punta a punta".
-- ============================================================
begin;

do $$
declare
  v_cli   uuid;
  v_cli2  uuid;
  v_fr    uuid;
  v_fr2   uuid;
  v_ag    uuid;
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  v_s     record;
  v_n     int;
  v_ver   int;
begin
  insert into clientes (nombre, email, documento) values ('Prueba GCal', 'prueba@example.com', 'TEST-GCAL-1') returning id into v_cli;
  insert into clientes (nombre, email, documento) values ('Prueba GCal 2', 'prueba2@example.com', 'TEST-GCAL-2') returning id into v_cli2;

  -- ---------------------------------------------------------------
  -- P1. Crear franja LIBRE no genera sincronización (no es cita)
  -- ---------------------------------------------------------------
  insert into horarios (fecha, hora, plataforma, profesor, duracion, modalidad, estado)
  values (v_hoy + 3, '19:00', 'powerbi', 'profe@taseca.tech', 60, 'Virtual', 'libre')
  returning id into v_fr;
  assert not exists (select 1 from gcal_sync where origen='horarios' and registro_id=v_fr), 'P1: una franja libre no debe encolarse';

  -- ---------------------------------------------------------------
  -- P2. CREAR CITA: reservar la franja la encola como pendiente
  -- ---------------------------------------------------------------
  update horarios set estado = 'reservado', cliente_id = v_cli where id = v_fr;
  select * into v_s from gcal_sync where origen='horarios' and registro_id=v_fr;
  assert v_s.estado = 'pendiente' and v_s.version = 1, 'P2: la reserva debe quedar pendiente (v1)';
  assert v_s.fecha_cita = v_hoy + 3, 'P2: fecha_cita';
  assert (select activa from gcal_citas where origen='horarios' and registro_id=v_fr), 'P2: la vista debe verla activa';
  assert (select tipo from gcal_citas where origen='horarios' and registro_id=v_fr) = 'Clase Power BI', 'P2: tipo';
  assert (select cliente_nombre from gcal_citas where origen='horarios' and registro_id=v_fr) = 'Prueba GCal', 'P2: nombre estudiante';

  -- ---------------------------------------------------------------
  -- P3. Cambios irrelevantes (marcar "completada") no re-sincronizan
  -- ---------------------------------------------------------------
  update horarios set completada = true where id = v_fr;
  assert (select version from gcal_sync where origen='horarios' and registro_id=v_fr) = 1, 'P3: completada no debe cambiar version';

  -- ---------------------------------------------------------------
  -- P4. CITA YA SINCRONIZADA: simular éxito de Google
  -- ---------------------------------------------------------------
  select count(*) into v_n from gcal_sync_reclamar(10, 'horarios', v_fr);
  assert v_n = 1, 'P4: debe poder reclamarse';
  perform gcal_sync_finalizar('horarios', v_fr, 1, true, 'sincronizado', 'creado', 'evt_123', 'https://cal/evt_123', 'https://meet.google.com/abc');
  select * into v_s from gcal_sync where origen='horarios' and registro_id=v_fr;
  assert v_s.estado = 'sincronizado' and v_s.gcal_event_id = 'evt_123' and v_s.meet_url like 'https://meet%', 'P4: mapeo guardado';
  select count(*) into v_n from gcal_sync_reclamar(10, 'horarios', v_fr);
  assert v_n = 0, 'P4: una cita sincronizada no vuelve a la cola';
  perform gcal_sync_reconciliar(14, false);
  assert (select estado from gcal_sync where origen='horarios' and registro_id=v_fr) = 'sincronizado', 'P4: reconciliación ligera no la toca';

  -- ---------------------------------------------------------------
  -- P5. MODIFICAR CITA: cambia la hora → misma fila, version 2, conserva event_id
  -- ---------------------------------------------------------------
  update horarios set hora = '20:00' where id = v_fr;
  select * into v_s from gcal_sync where origen='horarios' and registro_id=v_fr;
  assert v_s.estado = 'pendiente' and v_s.version = 2 and v_s.gcal_event_id = 'evt_123', 'P5: actualizar reutiliza el mismo evento';
  assert (select count(*) from gcal_sync where origen='horarios' and registro_id=v_fr) = 1, 'P5: nunca 2 filas por cita';

  -- ---------------------------------------------------------------
  -- P6. CITA DUPLICADA / CONCURRENCIA: dos procesos a la vez
  -- ---------------------------------------------------------------
  select count(*) into v_n from gcal_sync_reclamar(10, 'horarios', v_fr);
  assert v_n = 1, 'P6: el primer proceso la toma';
  select count(*) into v_n from gcal_sync_reclamar(10, 'horarios', v_fr);
  assert v_n = 0, 'P6: el segundo proceso NO la toma (bloqueada)';

  -- P6b. La cita cambia MIENTRAS se sincroniza → queda pendiente otra vez
  update horarios set hora = '20:30' where id = v_fr;              -- version 3
  perform gcal_sync_finalizar('horarios', v_fr, 2, true, 'sincronizado', 'actualizado', 'evt_123');
  assert (select estado from gcal_sync where origen='horarios' and registro_id=v_fr) = 'pendiente', 'P6b: cambio en carrera no se pierde';

  -- ---------------------------------------------------------------
  -- P7. ERROR DE GOOGLE CALENDAR → estado error + espera de reintento
  -- ---------------------------------------------------------------
  update gcal_sync set bloqueado_hasta = null where origen='horarios' and registro_id=v_fr;
  select version into v_ver from gcal_sync where origen='horarios' and registro_id=v_fr;
  perform gcal_sync_reclamar(10, 'horarios', v_fr);
  perform gcal_sync_finalizar('horarios', v_fr, v_ver, false, p_error => 'Apps Script respondió 500');
  select * into v_s from gcal_sync where origen='horarios' and registro_id=v_fr;
  assert v_s.estado = 'error' and v_s.intentos = 1 and v_s.ultimo_error like '%500%', 'P7: error registrado';
  assert v_s.proximo_intento_at > now(), 'P7: reintento programado a futuro';
  assert v_s.gcal_event_id = 'evt_123', 'P7: el error no borra el mapeo';
  assert exists (select 1 from gcal_sync_estado where registro_id=v_fr and estado_sync='error'), 'P7: visible en gcal_sync_estado';

  -- ---------------------------------------------------------------
  -- P8. REINTENTO: al llegar la hora vuelve a la cola y se resuelve
  -- ---------------------------------------------------------------
  select count(*) into v_n from gcal_sync_reclamar(10, 'horarios', v_fr);
  assert v_n = 0, 'P8: antes de la hora de reintento no se toma';
  update gcal_sync set proximo_intento_at = now() - interval '1 minute' where origen='horarios' and registro_id=v_fr;
  select count(*) into v_n from gcal_sync_reclamar(10, 'horarios', v_fr);
  assert v_n = 1, 'P8: al vencer la espera se reintenta';
  perform gcal_sync_finalizar('horarios', v_fr, v_ver, true, 'sincronizado', 'actualizado', 'evt_123');
  select * into v_s from gcal_sync where origen='horarios' and registro_id=v_fr;
  assert v_s.estado = 'sincronizado' and v_s.intentos = 0 and v_s.ultimo_error is null, 'P8: reintento exitoso limpia el error';

  -- ---------------------------------------------------------------
  -- P9. CANCELAR (Reagendar libera la franja) → pendiente y la vista la ve inactiva
  -- ---------------------------------------------------------------
  update horarios set estado = 'libre', cliente_id = null, completada = false where id = v_fr;
  assert (select estado from gcal_sync where origen='horarios' and registro_id=v_fr) = 'pendiente', 'P9: liberar encola la cancelación';
  assert not (select activa from gcal_citas where origen='horarios' and registro_id=v_fr), 'P9: ya no es cita activa';
  perform gcal_sync_reclamar(10, 'horarios', v_fr);
  select version into v_ver from gcal_sync where origen='horarios' and registro_id=v_fr;
  perform gcal_sync_finalizar('horarios', v_fr, v_ver, true, 'cancelado', 'cancelado', 'evt_123');
  assert (select estado from gcal_sync where origen='horarios' and registro_id=v_fr) = 'cancelado', 'P9: cancelado';

  -- P9b. La misma franja la reserva OTRO estudiante → vuelve a sincronizarse
  update horarios set estado = 'reservado', cliente_id = v_cli2 where id = v_fr;
  assert (select estado from gcal_sync where origen='horarios' and registro_id=v_fr) = 'pendiente', 'P9b: re-reserva encola';

  -- ---------------------------------------------------------------
  -- P10. AGENDA: crear, cancelar y eliminar
  -- ---------------------------------------------------------------
  insert into agenda (cliente_id, tipo, fecha, hora, duracion, modalidad, estado, notas)
  values (v_cli, 'Clase Excel', v_hoy + 5, '15:00', '90 min', 'Presencial', 'Programada', 'Tablas dinámicas')
  returning id into v_ag;
  assert (select estado from gcal_sync where origen='agenda' and registro_id=v_ag) = 'pendiente', 'P10: agenda nueva se encola';
  assert (select duracion_min from gcal_citas where origen='agenda' and registro_id=v_ag) = 90, 'P10: "90 min" → 90';

  update agenda set estado = 'Cancelada' where id = v_ag;
  assert (select version from gcal_sync where origen='agenda' and registro_id=v_ag) = 2, 'P10: cancelar re-encola';
  assert not (select activa from gcal_citas where origen='agenda' and registro_id=v_ag), 'P10: cancelada = inactiva';

  delete from agenda where id = v_ag;
  assert (select version from gcal_sync where origen='agenda' and registro_id=v_ag) = 3, 'P10: eliminar re-encola (para borrar el evento)';
  assert not exists (select 1 from gcal_citas where origen='agenda' and registro_id=v_ag), 'P10: ya no existe en origen';

  -- Una agenda creada directamente como Cancelada no se sincroniza
  insert into agenda (cliente_id, tipo, fecha, hora, duracion, modalidad, estado)
  values (v_cli, 'Reunión', v_hoy + 2, '10:00', '30 min', 'Virtual', 'Cancelada') returning id into v_ag;
  assert not exists (select 1 from gcal_sync where origen='agenda' and registro_id=v_ag), 'P10: cancelada desde el inicio no se encola';

  -- ---------------------------------------------------------------
  -- P11. RECUPERACIÓN: cita que existe en Supabase pero NO en la cola
  --      (p. ej. el trigger falló) → la reconciliación la encuentra
  -- ---------------------------------------------------------------
  insert into horarios (fecha, hora, plataforma, profesor, duracion, modalidad, estado, cliente_id)
  values (v_hoy + 4, '07:00', 'excel', 'profe@taseca.tech', 45, 'Virtual', 'reservado', v_cli)
  returning id into v_fr2;
  delete from gcal_sync where origen='horarios' and registro_id=v_fr2;           -- simula la pérdida
  assert exists (select 1 from gcal_sync_estado where registro_id=v_fr2 and estado_sync='sin_sincronizar'), 'P11: detectada como sin sincronizar';
  perform gcal_sync_reconciliar(14, false);
  assert (select estado from gcal_sync where origen='horarios' and registro_id=v_fr2) = 'pendiente', 'P11: reconciliación la recupera';

  -- P11b. Verificación completa re-comprueba incluso las ya sincronizadas
  perform gcal_sync_reclamar(10, 'horarios', v_fr2);
  perform gcal_sync_finalizar('horarios', v_fr2, 1, true, 'sincronizado', 'creado', 'evt_456');
  perform gcal_sync_reconciliar(14, true);
  assert (select estado from gcal_sync where origen='horarios' and registro_id=v_fr2) = 'pendiente', 'P11b: verificación completa';
  assert (select gcal_event_id from gcal_sync where origen='horarios' and registro_id=v_fr2) = 'evt_456', 'P11b: conserva el event_id';

  raise notice '✅ TODAS LAS PRUEBAS PASARON';
end $$;

rollback;
