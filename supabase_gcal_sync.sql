-- ============================================================
-- Taseca · Sincronización automática Supabase → Google Calendar
-- Ejecuta esto en: Supabase Dashboard > SQL Editor > New query
-- (después de los scripts anteriores: horarios y agenda ya existen)
-- ============================================================
-- Qué agrega, SIN tocar nada de lo que ya funciona:
--
--  1) Tabla "gcal_sync": una fila por cita (origen + id). Guarda el
--     ID del evento de Google Calendar, el estado de la sincronización,
--     los errores y los reintentos. Es a la vez el mapa
--     "cita Supabase → evento Google" y la cola de pendientes.
--
--  2) Vista "gcal_citas": la ÚNICA definición de "qué es una cita" para
--     la sincronización, uniendo las dos tablas reales:
--       · horarios → franja con estado <> 'libre' y con cliente_id
--       · agenda   → evento con estado <> 'Cancelada' que NO sea el
--                    gemelo de una franja (misma fecha, hora y clase):
--                    en las clases de estudiantes manda horarios
--
--  3) Triggers en "horarios" y "agenda": cuando una cita se crea,
--     cambia o se cancela/borra, la anotan en gcal_sync (en la misma
--     transacción → nunca se pierde) y avisan a la Edge Function
--     "gcal-sync" con pg_net (asíncrono → no frena la reserva).
--     Si algo de esto falla, la reserva/edición NO falla: solo deja un
--     WARNING en el log y la verificación periódica lo recupera.
--
--  4) Funciones de cola (reclamar / finalizar) que usa la Edge
--     Function, con bloqueo "SKIP LOCKED" para que dos procesos nunca
--     sincronicen la misma cita a la vez (anti-duplicados).
--
--  5) Reconciliación periódica con pg_cron (reintentos, citas sin
--     sincronizar y verificación completa contra Google).
--
--  6) Vista "gcal_sync_estado" para ver de un vistazo qué citas
--     próximas están sincronizadas y cuáles no.
--
-- Requisitos previos (Dashboard > Database > Extensions): habilitar
-- "pg_net" y "pg_cron". Las líneas de abajo lo intentan también.
-- ============================================================

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------
-- 1) TABLA DE SINCRONIZACIÓN
-- ---------------------------------------------------------------
create table if not exists public.gcal_sync (
  origen              text        not null check (origen in ('horarios','agenda')),
  registro_id         uuid        not null,
  gcal_event_id       text,
  gcal_html_link      text,
  meet_url            text,
  estado              text        not null default 'pendiente'
                      check (estado in ('pendiente','sincronizado','cancelado','error')),
  version             integer     not null default 1,   -- sube con cada cambio de la cita
  intentos            integer     not null default 0,
  ultimo_error        text,
  ultima_accion       text,                              -- creado / actualizado / sin_cambios / cancelado / no_existia
  proximo_intento_at  timestamptz not null default now(),
  bloqueado_hasta     timestamptz,
  fecha_cita          date,
  sincronizado_at     timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  primary key (origen, registro_id)                      -- 1 cita = 1 fila = 1 evento
);

create index if not exists gcal_sync_cola_idx
  on public.gcal_sync (proximo_intento_at)
  where estado in ('pendiente','error');

alter table public.gcal_sync enable row level security;

-- El panel (usuarios logueados) puede LEER el estado; solo el servidor
-- (service_role / funciones security definer) escribe.
drop policy if exists "authenticated can read gcal_sync" on public.gcal_sync;
create policy "authenticated can read gcal_sync"
  on public.gcal_sync for select to authenticated using (true);

revoke all on public.gcal_sync from anon;

-- ---------------------------------------------------------------
-- 2) VISTA UNIFICADA DE CITAS
-- ---------------------------------------------------------------
-- Columnas tomadas de los nombres reales del proyecto. Los "::text" y
-- el parseo de duración hacen que funcione aunque "horarios.fecha" o
-- "horarios.duracion" sean text o date/int.
create or replace view public.gcal_citas
with (security_invoker = true) as
select
  'horarios'::text                                            as origen,
  h.id                                                        as registro_id,
  (h.estado::text is distinct from 'libre' and h.cliente_id is not null) as activa,
  h.fecha::date                                               as fecha,
  left(h.hora::text, 8)                                       as hora,
  coalesce(nullif(regexp_replace(h.duracion::text, '\D', '', 'g'), '')::int, 60) as duracion_min,
  ('Clase ' || case h.plataforma::text when 'excel' then 'Excel'
                                       when 'powerbi' then 'Power BI'
                                       else coalesce(h.plataforma::text, '') end) as tipo,
  h.plataforma::text                                          as plataforma,
  h.modalidad::text                                           as modalidad,
  h.profesor::text                                            as profesor,
  null::text                                                  as notas,
  h.estado::text                                              as estado_origen,
  c.nombre                                                    as cliente_nombre,
  c.email                                                     as cliente_email,
  c.telefono                                                  as cliente_telefono,
  c.documento::text                                           as cliente_documento
from public.horarios h
left join public.clientes c on c.id = h.cliente_id
union all
select
  'agenda'::text,
  a.id,
  -- Activa si no está cancelada Y no es el "gemelo" de una franja de
  -- Plan de Estudio: reservar_franja_v2 guarda cada reserva en horarios
  -- Y en agenda. Para no duplicar el evento, en las clases de
  -- estudiantes manda la franja (horarios); agenda solo sincroniza lo
  -- que no tiene franja (demos, reuniones, soporte, clases manuales).
  (a.estado is distinct from 'Cancelada'
   and not exists (
     select 1 from public.horarios h
      where h.fecha::date = a.fecha::date
        and left(h.hora::text, 5) = left(a.hora::text, 5)
        and a.tipo = 'Clase ' || case h.plataforma::text when 'excel' then 'Excel'
                                                         when 'powerbi' then 'Power BI'
                                                         else coalesce(h.plataforma::text, '') end
        and (h.cliente_id = a.cliente_id or h.cliente_id is null))),
  a.fecha::date,
  left(a.hora::text, 8),
  coalesce(nullif(regexp_replace(a.duracion::text, '\D', '', 'g'), '')::int, 60),
  a.tipo,
  null::text,
  a.modalidad,
  a.profesor::text,
  a.notas,
  a.estado,
  c.nombre,
  c.email,
  c.telefono,
  c.documento::text
from public.agenda a
left join public.clientes c on c.id = a.cliente_id;

revoke all on public.gcal_citas from anon;

-- ---------------------------------------------------------------
-- 3) ENCOLAR + DISPARAR
-- ---------------------------------------------------------------
create or replace function public.gcal_sync_encolar(p_origen text, p_id uuid, p_fecha date)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into gcal_sync (origen, registro_id, fecha_cita)
  values (p_origen, p_id, p_fecha)
  on conflict (origen, registro_id) do update
    set estado             = 'pendiente',
        version            = gcal_sync.version + 1,
        intentos           = 0,
        proximo_intento_at = now(),
        fecha_cita         = coalesce(excluded.fecha_cita, gcal_sync.fecha_cita),
        updated_at         = now();
end;
$$;

-- Llama a la Edge Function con pg_net. La URL y el secreto viven en
-- Supabase Vault (ver paso 7 al final). pg_net envía la petición
-- DESPUÉS del commit, así la función ya ve la cita guardada.
create or replace function public.gcal_sync_disparar(p_origen text default null, p_id uuid default null)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url    text;
  v_secret text;
  v_req    bigint;
begin
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'gcal_sync_url'    limit 1;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'gcal_sync_secret' limit 1;
  if v_url is null or v_secret is null then
    raise warning 'gcal_sync: faltan los secretos gcal_sync_url / gcal_sync_secret en Vault';
    return null;
  end if;

  select net.http_post(
    url     := v_url,
    body    := jsonb_build_object('modo', 'procesar', 'origen', p_origen, 'registro_id', p_id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', v_secret),
    timeout_milliseconds := 60000
  ) into v_req;
  return v_req;
end;
$$;

-- Lógica común de los triggers. Nunca lanza error hacia afuera.
create or replace function public.gcal_sync_tras_cambio(p_origen text, p_id uuid, p_fecha_txt text, p_relevante boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fecha date;
begin
  if not p_relevante
     and not exists (select 1 from gcal_sync where origen = p_origen and registro_id = p_id) then
    return;   -- p. ej. crear/borrar franjas libres: no son citas, no ensucian la cola
  end if;

  begin
    v_fecha := nullif(p_fecha_txt, '')::date;
  exception when others then
    v_fecha := null;
  end;

  begin
    perform gcal_sync_encolar(p_origen, p_id, v_fecha);
  exception when others then
    raise warning 'gcal_sync: no se pudo encolar %/%: %', p_origen, p_id, sqlerrm;
    return;   -- la verificación periódica la encontrará igual
  end;

  begin
    perform gcal_sync_disparar(p_origen, p_id);
  exception when others then
    raise warning 'gcal_sync: no se pudo disparar %/%: % (queda pendiente para el cron)', p_origen, p_id, sqlerrm;
  end;
end;
$$;

-- Trigger de HORARIOS
create or replace function public.trg_gcal_sync_horarios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cita_new boolean := false;
  v_cita_old boolean := false;
begin
  begin
    if tg_op in ('INSERT','UPDATE') then
      v_cita_new := (new.estado::text is distinct from 'libre' and new.cliente_id is not null);
    end if;
    if tg_op in ('UPDATE','DELETE') then
      v_cita_old := (old.estado::text is distinct from 'libre' and old.cliente_id is not null);
    end if;

    if tg_op = 'UPDATE' and not (
         new.fecha      is distinct from old.fecha
      or new.hora       is distinct from old.hora
      or new.duracion   is distinct from old.duracion
      or new.estado     is distinct from old.estado
      or new.cliente_id is distinct from old.cliente_id
      or new.profesor   is distinct from old.profesor
      or new.modalidad  is distinct from old.modalidad
      or new.plataforma is distinct from old.plataforma
    ) then
      return null;   -- p. ej. solo cambió "completada": no afecta al calendario
    end if;

    if tg_op = 'DELETE' then
      perform gcal_sync_tras_cambio('horarios', old.id, old.fecha::text, v_cita_old);
    else
      perform gcal_sync_tras_cambio('horarios', new.id, new.fecha::text, v_cita_new or v_cita_old);
    end if;
  exception when others then
    raise warning 'gcal_sync trigger horarios: %', sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists gcal_sync_horarios on public.horarios;
create trigger gcal_sync_horarios
  after insert or update or delete on public.horarios
  for each row execute function public.trg_gcal_sync_horarios();

-- Trigger de AGENDA
create or replace function public.trg_gcal_sync_agenda()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if tg_op = 'UPDATE' and not (
         new.fecha      is distinct from old.fecha
      or new.hora       is distinct from old.hora
      or new.duracion   is distinct from old.duracion
      or new.estado     is distinct from old.estado
      or new.cliente_id is distinct from old.cliente_id
      or new.tipo       is distinct from old.tipo
      or new.modalidad  is distinct from old.modalidad
      or new.profesor   is distinct from old.profesor
      or new.notas      is distinct from old.notas
    ) then
      return null;
    end if;

    if tg_op = 'DELETE' then
      perform gcal_sync_tras_cambio('agenda', old.id, old.fecha::text, old.estado is distinct from 'Cancelada');
    else
      perform gcal_sync_tras_cambio('agenda', new.id, new.fecha::text,
        new.estado is distinct from 'Cancelada'
        or (tg_op = 'UPDATE' and old.estado is distinct from 'Cancelada'));
    end if;
  exception when others then
    raise warning 'gcal_sync trigger agenda: %', sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists gcal_sync_agenda on public.agenda;
create trigger gcal_sync_agenda
  after insert or update or delete on public.agenda
  for each row execute function public.trg_gcal_sync_agenda();

-- ---------------------------------------------------------------
-- 4) COLA: reclamar y finalizar (los usa la Edge Function)
-- ---------------------------------------------------------------
create or replace function public.gcal_sync_reclamar(
  p_limite int default 10,
  p_origen text default null,
  p_registro_id uuid default null
) returns setof public.gcal_sync
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  update gcal_sync g
     set bloqueado_hasta = now() + interval '3 minutes'
   where (g.origen, g.registro_id) in (
          select s.origen, s.registro_id
            from gcal_sync s
           where s.estado in ('pendiente','error')
             and s.proximo_intento_at <= now()
             and (s.bloqueado_hasta is null or s.bloqueado_hasta < now())
             and (p_registro_id is null or (s.origen = p_origen and s.registro_id = p_registro_id))
           order by s.proximo_intento_at
           limit greatest(p_limite, 1)
           for update skip locked)
  returning g.*;
end;
$$;

create or replace function public.gcal_sync_finalizar(
  p_origen      text,
  p_registro_id uuid,
  p_version     int,
  p_ok          boolean,
  p_estado      text default null,   -- 'sincronizado' | 'cancelado' (si p_ok)
  p_accion      text default null,
  p_event_id    text default null,
  p_html_link   text default null,
  p_meet_url    text default null,
  p_error       text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_ok then
    update gcal_sync
       set gcal_event_id   = coalesce(p_event_id, gcal_event_id),
           gcal_html_link  = coalesce(p_html_link, gcal_html_link),
           meet_url        = case when p_estado = 'cancelado' then meet_url else coalesce(p_meet_url, meet_url) end,
           ultima_accion   = p_accion,
           ultimo_error    = null,
           bloqueado_hasta = null,
           sincronizado_at = now(),
           updated_at      = now(),
           -- si la cita cambió MIENTRAS se sincronizaba, queda pendiente otra vez
           estado          = case when version = p_version then p_estado else 'pendiente' end,
           intentos        = case when version = p_version then 0 else intentos end,
           proximo_intento_at = now()
     where origen = p_origen and registro_id = p_registro_id;
  else
    update gcal_sync
       set intentos        = intentos + 1,
           ultimo_error    = left(coalesce(p_error, 'error desconocido'), 1000),
           bloqueado_hasta = null,
           updated_at      = now(),
           estado          = case when version = p_version then 'error' else 'pendiente' end,
           -- reintento con espera creciente: 2, 4, 8, 16, 32, 60, 60... minutos
           proximo_intento_at = case when version = p_version
                                     then now() + make_interval(mins => least(60, power(2, least(intentos + 1, 6))::int))
                                     else now() end
     where origen = p_origen and registro_id = p_registro_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------
-- 5) RECONCILIACIÓN (red de seguridad)
-- ---------------------------------------------------------------
-- p_verificar_todo = false → solo encola lo que esté desalineado:
--    · citas próximas sin fila en gcal_sync
--    · filas "sincronizado" cuya cita ya no está activa o ya no existe
--    · filas "cancelado" cuya cita volvió a estar activa
-- p_verificar_todo = true → además vuelve a comprobar TODAS las citas
--    próximas contra Google (si borraste el evento a mano, se recrea).
create or replace function public.gcal_sync_reconciliar(p_dias int default 14, p_verificar_todo boolean default false)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  v_n     int  := 0;
  r       record;
begin
  for r in
    -- citas activas próximas sin sincronizar (o todas si p_verificar_todo)
    select c.origen, c.registro_id, c.fecha
      from gcal_citas c
      left join gcal_sync s on s.origen = c.origen and s.registro_id = c.registro_id
     where c.activa
       and c.fecha between v_hoy and v_hoy + p_dias
       and (s.registro_id is null
            or s.estado = 'cancelado'
            or (p_verificar_todo and s.estado = 'sincronizado'))
    union
    -- eventos sincronizados cuya cita ya no está activa / ya no existe
    select s.origen, s.registro_id, s.fecha_cita
      from gcal_sync s
      left join gcal_citas c on c.origen = s.origen and c.registro_id = s.registro_id
     where s.estado = 'sincronizado'
       and (c.registro_id is null or not c.activa)
  loop
    perform gcal_sync_encolar(r.origen, r.registro_id, r.fecha);
    v_n := v_n + 1;
  end loop;

  -- desbloquea filas que quedaron "colgadas" (p. ej. la función se cayó)
  update gcal_sync set bloqueado_hasta = null
   where bloqueado_hasta < now() - interval '10 minutes';

  return v_n;
end;
$$;

-- ---------------------------------------------------------------
-- 6) VISTA DE ESTADO (para revisar desde el SQL Editor)
-- ---------------------------------------------------------------
--   select * from gcal_sync_estado;                          -- todo lo próximo
--   select * from gcal_sync_estado where estado_sync <> 'sincronizado';
create or replace view public.gcal_sync_estado
with (security_invoker = true) as
select
  c.origen,
  c.registro_id,
  c.fecha,
  c.hora,
  c.tipo,
  c.cliente_nombre,
  c.activa,
  coalesce(s.estado, 'sin_sincronizar') as estado_sync,
  s.ultima_accion,
  s.intentos,
  s.ultimo_error,
  s.proximo_intento_at,
  s.gcal_event_id,
  s.meet_url,
  s.sincronizado_at
from public.gcal_citas c
left join public.gcal_sync s on s.origen = c.origen and s.registro_id = c.registro_id
where c.fecha >= (now() at time zone 'America/Bogota')::date
  and (c.activa or s.registro_id is not null)
order by c.fecha, c.hora;

revoke all on public.gcal_sync_estado from anon;

-- ---------------------------------------------------------------
-- PERMISOS: las funciones internas NO se pueden llamar desde el
-- navegador (ni anon ni authenticated). Solo service_role.
-- ---------------------------------------------------------------
revoke execute on function public.gcal_sync_encolar(text, uuid, date)                    from public, anon, authenticated;
revoke execute on function public.gcal_sync_disparar(text, uuid)                         from public, anon, authenticated;
revoke execute on function public.gcal_sync_tras_cambio(text, uuid, text, boolean)       from public, anon, authenticated;
revoke execute on function public.gcal_sync_reclamar(int, text, uuid)                    from public, anon, authenticated;
revoke execute on function public.gcal_sync_finalizar(text, uuid, int, boolean, text, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.gcal_sync_reconciliar(int, boolean)                    from public, anon, authenticated;

grant execute on function public.gcal_sync_reclamar(int, text, uuid)                     to service_role;
grant execute on function public.gcal_sync_finalizar(text, uuid, int, boolean, text, text, text, text, text, text) to service_role;
grant execute on function public.gcal_sync_reconciliar(int, boolean)                     to service_role;
grant execute on function public.gcal_sync_disparar(text, uuid)                          to service_role;
grant select on public.gcal_citas, public.gcal_sync_estado to service_role, authenticated;
grant select, insert, update on public.gcal_sync to service_role;

-- ---------------------------------------------------------------
-- 7) TAREAS PROGRAMADAS (pg_cron, horario en UTC)
-- ---------------------------------------------------------------
-- Cada 10 min: procesa pendientes y reintentos con error.
select cron.schedule('gcal-sync-reintentos', '*/10 * * * *',
  $$ select public.gcal_sync_disparar(); $$);

-- Cada hora (minuto 5): busca citas desalineadas y las procesa.
select cron.schedule('gcal-sync-reconciliar', '5 * * * *',
  $$ select public.gcal_sync_reconciliar(14, false); select public.gcal_sync_disparar(); $$);

-- Cada 6 horas (minuto 20): verificación completa de las próximas 2 semanas.
select cron.schedule('gcal-sync-verificacion', '20 */6 * * *',
  $$ select public.gcal_sync_reconciliar(14, true); select public.gcal_sync_disparar(); $$);

-- ============================================================
-- 8) SECRETOS EN VAULT  (NO se ejecuta solo: córrelo UNA vez a mano,
--    reemplazando los valores. Ver docs/GCAL_SYNC.md, paso 4)
-- ============================================================
--   select vault.create_secret('https://<TU-PROJECT-REF>.supabase.co/functions/v1/gcal-sync', 'gcal_sync_url');
--   select vault.create_secret('<EL MISMO GCAL_SYNC_SECRET DE LA EDGE FUNCTION>', 'gcal_sync_secret');
--
-- Sincronización inicial de las citas futuras que ya existen:
--   select public.gcal_sync_reconciliar(60, false);
--   select public.gcal_sync_disparar();
-- ============================================================
