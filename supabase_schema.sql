-- ============================================================
-- Taseca Panel de Administración — esquema de Supabase (v2)
-- Tablas separadas por módulo: clientes, ventas, facturas, agenda,
-- cotizaciones y config.
-- Ejecuta este script completo en: Supabase Dashboard > SQL Editor > New query
-- ============================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------
-- CLIENTES
-- ---------------------------------------------------------------
create table if not exists clientes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  sector text,
  ciudad text,
  producto text,
  plan text,
  email text,
  telefono text,
  estado text,
  valor_mensual numeric default 0,
  fecha_registro date default current_date,
  notas text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------
-- VENTAS (pipeline / oportunidades)
-- ---------------------------------------------------------------
create table if not exists ventas (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid references clientes(id) on delete set null,
  nombre_lead text,
  producto text,
  plan text,
  valor numeric default 0,
  etapa text,
  fecha date default current_date,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------
-- FACTURAS
-- ---------------------------------------------------------------
create table if not exists facturas (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid references clientes(id) on delete set null,
  producto text,
  concepto text,
  monto numeric default 0,
  fecha_emision date,
  fecha_venc date,
  estado text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------
-- AGENDA (clases, demos, citas)
-- ---------------------------------------------------------------
create table if not exists agenda (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid references clientes(id) on delete set null,
  tipo text,
  fecha date,
  hora text,
  duracion text,
  modalidad text,
  estado text,
  notas text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------
-- COTIZACIONES
-- ---------------------------------------------------------------
create table if not exists cotizaciones (
  id uuid primary key default gen_random_uuid(),
  numero text,
  fecha date default current_date,
  validez_dias int default 15,
  estado text default 'Borrador',
  cliente_id uuid references clientes(id) on delete set null,
  cliente_nombre text,
  cliente_contacto text,
  cliente_email text,
  consultor_nombre text,
  consultor_cargo text,
  consultor_contacto text,
  tipo_servicio text,
  titulo text,
  resumen text,
  fases jsonb default '[]'::jsonb,
  items jsonb default '[]'::jsonb,
  iva_pct numeric default 19,
  forma_pago text,
  tiempo_ejecucion text,
  notas_adicionales text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------
-- CONFIG (fila única con ajustes generales del panel)
-- ---------------------------------------------------------------
create table if not exists config (
  id int primary key default 1,
  empresa text default 'Taseca Software',
  consultor_nombre text default 'Equipo Comercial',
  consultor_cargo text default 'Consultor de Soluciones',
  consultor_contacto text default 'contacto@taseca.tech',
  cotizacion_seq int default 1,
  constraint config_singleton check (id = 1)
);
insert into config (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------
-- SEGURIDAD (RLS): solo usuarios logueados en el panel pueden
-- leer/escribir. La fila de "config" no admite insert/delete desde
-- la app (solo lectura y actualización), ya que siempre existe una
-- única fila creada por este script.
-- ---------------------------------------------------------------
alter table clientes enable row level security;
alter table ventas enable row level security;
alter table facturas enable row level security;
alter table agenda enable row level security;
alter table cotizaciones enable row level security;
alter table config enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['clientes','ventas','facturas','agenda','cotizaciones'] loop
    execute format('drop policy if exists "authenticated full access" on %I', t);
    execute format(
      'create policy "authenticated full access" on %I for all to authenticated using (true) with check (true)',
      t
    );
  end loop;
end $$;

drop policy if exists "authenticated can read config" on config;
create policy "authenticated can read config"
  on config for select to authenticated using (true);

drop policy if exists "authenticated can update config" on config;
create policy "authenticated can update config"
  on config for update to authenticated using (true) with check (true);

-- ============================================================
-- Usuarios (login del panel)
-- ============================================================
-- No hay registro público en este panel. Crea las cuentas del equipo desde:
--   Supabase Dashboard > Authentication > Users > Add user
-- Marca "Auto Confirm User" al crearlas para que puedan iniciar sesión de
-- inmediato (sin confirmar un correo).
-- ============================================================

-- ============================================================
-- Limpieza opcional: la versión anterior del panel usaba una sola
-- tabla "app_state" con todo en un JSON. Ya no se usa. Una vez
-- verifiques que el panel funciona bien con las tablas de arriba,
-- puedes borrarla ejecutando (opcional, no se ejecuta automáticamente):
--   drop table if exists app_state;
-- ============================================================
