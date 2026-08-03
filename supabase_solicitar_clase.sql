-- ============================================================
-- Función pública para el formulario de estudiantes (agendar-clase.html)
-- Ejecuta esto en: Supabase Dashboard > SQL Editor > New query
-- (después de haber corrido supabase_schema.sql)
-- ============================================================
-- Por qué una función y no permisos de INSERT directos a "anon":
-- así el público solo puede ejecutar EXACTAMENTE esta acción (crear
-- una solicitud de clase), sin poder leer ni modificar ningún otro
-- dato de las tablas clientes/agenda. La función corre con permisos
-- elevados (security definer) sólo para este propósito puntual.
-- ============================================================

create or replace function public.solicitar_clase(
  p_nombre text,
  p_email text,
  p_telefono text,
  p_tipo_clase text,   -- 'Clase Excel' o 'Clase Power BI'
  p_fecha date,
  p_hora text,
  p_modalidad text,    -- 'Virtual' o 'Presencial'
  p_notas text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id uuid;
begin
  if p_nombre is null or length(trim(p_nombre)) = 0 then
    raise exception 'El nombre es obligatorio';
  end if;
  if p_email is null or length(trim(p_email)) = 0 then
    raise exception 'El correo es obligatorio';
  end if;
  if p_tipo_clase not in ('Clase Excel','Clase Power BI') then
    raise exception 'Tipo de clase inválido';
  end if;
  if p_modalidad not in ('Virtual','Presencial') then
    p_modalidad := 'Virtual';
  end if;

  -- Reutiliza el cliente si ya había solicitado antes con el mismo correo
  select id into v_cliente_id
  from clientes
  where email = p_email and producto = 'excel-bi'
  limit 1;

  if v_cliente_id is null then
    insert into clientes (nombre, email, telefono, producto, estado, sector, valor_mensual)
    values (p_nombre, p_email, coalesce(p_telefono,''), 'excel-bi', 'Lead', 'Estudiante', 0)
    returning id into v_cliente_id;
  end if;

  insert into agenda (cliente_id, tipo, fecha, hora, duracion, modalidad, estado, notas)
  values (v_cliente_id, p_tipo_clase, p_fecha, p_hora, '60 min', p_modalidad, 'Programada', coalesce(p_notas,''));
end;
$$;

-- Solo permite EJECUTAR esta función puntual al público (rol "anon"),
-- no acceso directo a las tablas.
grant execute on function public.solicitar_clase(text,text,text,text,date,text,text,text) to anon;
