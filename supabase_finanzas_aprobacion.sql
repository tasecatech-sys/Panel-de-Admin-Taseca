-- ============================================================
-- Taseca · Aprobación de movimientos de Finanzas
-- Ejecuta esto en: Supabase Dashboard > SQL Editor > New query
-- (después de que existan fin_movimientos y staff_usuarios)
-- ============================================================
-- Flujo:
--   1) Un administrador registra un ingreso, gasto o pago a socio
--      → queda en estado 'pendiente' (no cuenta en totales ni caja).
--   2) El usuario con rol 'aprobador' lo aprueba o lo rechaza (con motivo).
--   3) Si un administrador edita un movimiento aprobado (tipo, fecha,
--      categoría, socio, concepto, monto o método), vuelve a 'pendiente'.
--   4) Un movimiento aprobado no se puede eliminar; el aprobador puede
--      "revertirlo" (rechazarlo) y entonces el administrador lo elimina.
--
-- Todo esto lo hace cumplir la BASE DE DATOS (trigger + RLS), no solo
-- el panel: aunque alguien llame a la API directamente, un
-- administrador no puede aprobar y el aprobador no puede crear ni
-- cambiar montos.
--
-- Desde el SQL Editor (sin usuario logueado) no se aplican las
-- restricciones, para poder hacer mantenimiento.
-- ============================================================

-- ---------------------------------------------------------------
-- 1) Nuevo rol 'aprobador' en staff_usuarios
-- ---------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
     where conrelid = 'public.staff_usuarios'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%rol%'
  loop
    execute format('alter table public.staff_usuarios drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.staff_usuarios
  add constraint staff_usuarios_rol_check
  check (rol in ('admin', 'profesor', 'contador', 'aprobador'));

create or replace function public.es_aprobador_panel()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from staff_usuarios
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and rol = 'aprobador'
      and coalesce(activo, true)
  );
$$;

-- ---------------------------------------------------------------
-- 2) Columnas de aprobación en fin_movimientos
-- ---------------------------------------------------------------
alter table public.fin_movimientos add column if not exists estado text;
alter table public.fin_movimientos add column if not exists aprobado_por text;
alter table public.fin_movimientos add column if not exists aprobado_at timestamptz;
alter table public.fin_movimientos add column if not exists motivo_rechazo text;

-- Los movimientos que ya existían son históricos: quedan aprobados
-- (así los totales actuales no cambian).
update public.fin_movimientos
   set estado = 'aprobado',
       aprobado_por = coalesce(aprobado_por, 'histórico'),
       aprobado_at = coalesce(aprobado_at, now())
 where estado is null;

alter table public.fin_movimientos alter column estado set default 'pendiente';
alter table public.fin_movimientos alter column estado set not null;

alter table public.fin_movimientos drop constraint if exists fin_movimientos_estado_check;
alter table public.fin_movimientos
  add constraint fin_movimientos_estado_check
  check (estado in ('pendiente', 'aprobado', 'rechazado'));

create index if not exists fin_movimientos_estado_idx on public.fin_movimientos (estado);

-- ---------------------------------------------------------------
-- 3) Reglas (trigger)
-- ---------------------------------------------------------------
create or replace function public.trg_fin_movimientos_aprobacion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rol   text := current_staff_role();   -- null = SQL Editor / service_role
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_cambio_importante boolean;
begin
  if v_rol is null then
    return coalesce(new, old);             -- mantenimiento: sin restricciones
  end if;

  -- ---------- INSERT: siempre nace pendiente ----------
  if tg_op = 'INSERT' then
    if v_rol <> 'admin' then
      raise exception 'Solo un administrador puede registrar movimientos.';
    end if;
    new.estado         := 'pendiente';
    new.aprobado_por   := null;
    new.aprobado_at    := null;
    new.motivo_rechazo := null;
    return new;
  end if;

  -- ---------- DELETE ----------
  if tg_op = 'DELETE' then
    if v_rol <> 'admin' then
      raise exception 'Solo un administrador puede eliminar movimientos.';
    end if;
    if old.estado = 'aprobado' then
      raise exception 'Un movimiento aprobado no se puede eliminar. Pide al aprobador que lo revierta (rechace) primero.';
    end if;
    return old;
  end if;

  -- ---------- UPDATE ----------
  v_cambio_importante :=
       new.tipo        is distinct from old.tipo
    or new.fecha       is distinct from old.fecha
    or new.categoria   is distinct from old.categoria
    or new.socio       is distinct from old.socio
    or new.concepto    is distinct from old.concepto
    or new.monto       is distinct from old.monto
    or new.metodo_pago is distinct from old.metodo_pago;

  if v_rol = 'aprobador' then
    -- El aprobador solo decide: no puede cambiar datos del movimiento.
    if v_cambio_importante
       or new.notas is distinct from old.notas
       or new.created_by is distinct from old.created_by then
      raise exception 'El aprobador solo puede aprobar o rechazar, no modificar el movimiento.';
    end if;
    if new.estado not in ('aprobado', 'rechazado') then
      raise exception 'Estado inválido: usa aprobado o rechazado.';
    end if;
    if new.estado = 'rechazado' and coalesce(trim(new.motivo_rechazo), '') = '' then
      raise exception 'Escribe el motivo del rechazo.';
    end if;
    new.aprobado_por := v_email;
    new.aprobado_at  := now();
    if new.estado = 'aprobado' then new.motivo_rechazo := null; end if;
    return new;
  end if;

  if v_rol = 'admin' then
    -- El administrador no puede aprobar ni rechazar: esos campos no se tocan…
    new.estado         := old.estado;
    new.aprobado_por   := old.aprobado_por;
    new.aprobado_at    := old.aprobado_at;
    new.motivo_rechazo := old.motivo_rechazo;
    -- …y si cambia algo importante, vuelve a revisión.
    if v_cambio_importante then
      new.estado         := 'pendiente';
      new.aprobado_por   := null;
      new.aprobado_at    := null;
      new.motivo_rechazo := null;
    end if;
    return new;
  end if;

  raise exception 'Tu rol no puede modificar movimientos de finanzas.';
end;
$$;

drop trigger if exists fin_movimientos_aprobacion on public.fin_movimientos;
create trigger fin_movimientos_aprobacion
  before insert or update or delete on public.fin_movimientos
  for each row execute function public.trg_fin_movimientos_aprobacion();

-- ---------------------------------------------------------------
-- 4) Permisos (RLS): el aprobador ve Finanzas y solo puede
--    actualizar movimientos (aprobar / rechazar). Préstamos: solo lectura.
--    Las políticas "solo admin" existentes se mantienen.
-- ---------------------------------------------------------------
drop policy if exists "aprobador lee movimientos" on public.fin_movimientos;
create policy "aprobador lee movimientos" on public.fin_movimientos
  for select to authenticated using (es_aprobador_panel());

drop policy if exists "aprobador decide movimientos" on public.fin_movimientos;
create policy "aprobador decide movimientos" on public.fin_movimientos
  for update to authenticated using (es_aprobador_panel()) with check (es_aprobador_panel());

drop policy if exists "aprobador lee prestamos" on public.fin_prestamos;
create policy "aprobador lee prestamos" on public.fin_prestamos
  for select to authenticated using (es_aprobador_panel());

drop policy if exists "aprobador lee pagos de prestamos" on public.fin_prestamo_pagos;
create policy "aprobador lee pagos de prestamos" on public.fin_prestamo_pagos
  for select to authenticated using (es_aprobador_panel());

revoke execute on function public.trg_fin_movimientos_aprobacion() from public, anon, authenticated;
grant execute on function public.es_aprobador_panel() to authenticated;

-- ============================================================
-- Revisión rápida (opcional):
--   select estado, count(*) from fin_movimientos group by estado;
-- ============================================================
