-- ============================================================
-- Taseca · Agendamiento con verificación por documento (v2)
-- Ejecuta esto en: Supabase Dashboard > SQL Editor > New query
-- ============================================================
-- Qué agrega, sin tocar nada de lo que ya funciona:
--
-- 1) buscar_estudiante_por_documento(p_documento)
--    Función pública (rol "anon") que busca en "clientes" por el
--    número de documento y devuelve nombre/email/teléfono si existe.
--    Es el "mini login" del formulario de agendamiento: el
--    estudiante ya debe existir en la base de datos (lo agrega el
--    admin desde el panel, pestaña Clientes, campo "Documento /
--    Cédula"). No permite leer ninguna otra columna ni tabla.
--
-- 2) reservar_franja_v2(p_franja_id, p_documento, p_notas)
--    Nueva versión de la reserva de horario que YA NO acepta
--    nombre/email/teléfono escritos a mano: exige un documento que
--    exista en "clientes" y usa esos datos. Si el documento no
--    existe, devuelve ok:false y NO reserva nada (bloqueo total,
--    tal como se pidió). No reemplaza ni borra la función
--    "reservar_franja" original -- agendar-clase.html debe
--    actualizarse para llamar a esta nueva en su lugar.
--
--    También devuelve "profesor" (el correo que quedó asignado a
--    esa franja al crearla desde el panel) para que el frontend
--    pueda avisarle por correo/WhatsApp.
-- ============================================================

create or replace function public.buscar_estudiante_por_documento(
  p_documento text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente record;
begin
  if p_documento is null or length(trim(p_documento)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu número de documento.');
  end if;

  select nombre, email, telefono
  into v_cliente
  from clientes
  where documento = trim(p_documento)
  limit 1;

  if v_cliente is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'No encontramos ese documento en nuestra base de datos. Contáctanos para registrarte antes de agendar.'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'nombre', v_cliente.nombre,
    'email', v_cliente.email,
    'telefono', v_cliente.telefono
  );
end;
$$;

grant execute on function public.buscar_estudiante_por_documento(text) to anon;


create or replace function public.reservar_franja_v2(
  p_franja_id uuid,
  p_documento text,
  p_notas text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente record;
  v_franja record;
begin
  if p_documento is null or length(trim(p_documento)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu número de documento.');
  end if;

  select id, nombre, email, telefono
  into v_cliente
  from clientes
  where documento = trim(p_documento)
  limit 1;

  if v_cliente is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'No encontramos ese documento en nuestra base de datos. Contáctanos para registrarte antes de agendar.'
    );
  end if;

  select id, fecha, hora, plataforma, estado, profesor
  into v_franja
  from horarios
  where id = p_franja_id
  for update;

  if v_franja is null then
    return jsonb_build_object('ok', false, 'error', 'Ese horario ya no existe. Elige otro.');
  end if;

  if v_franja.estado <> 'libre' then
    return jsonb_build_object('ok', false, 'error', 'Ese horario ya no está disponible. Elige otro.');
  end if;

  update horarios
  set estado = 'reservada',
      cliente_id = v_cliente.id
  where id = p_franja_id;

  if p_notas is not null and length(trim(p_notas)) > 0 then
    update clientes
    set notas = trim(coalesce(notas || E'\n', '') || '[Agendamiento] ' || trim(p_notas))
    where id = v_cliente.id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'plataforma', v_franja.plataforma,
    'fecha', v_franja.fecha,
    'hora', v_franja.hora,
    'profesor', v_franja.profesor,
    'nombre', v_cliente.nombre
  );
end;
$$;

grant execute on function public.reservar_franja_v2(uuid, text, text) to anon;
