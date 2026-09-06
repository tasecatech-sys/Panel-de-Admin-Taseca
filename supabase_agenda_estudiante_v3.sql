-- ============================================================
-- Taseca · WhatsApp por profesor + mejor manejo de errores (v3)
-- Ejecuta esto en: Supabase Dashboard > SQL Editor > New query
-- (después de haber corrido supabase_agenda_estudiante_v2.sql)
-- ============================================================
-- Qué agrega, sin tocar nada de lo que ya funciona:
--
-- 1) Columna "whatsapp" en staff_usuarios: el número de WhatsApp de
--    cada profesor (se edita desde el panel, Configuración > Gestión
--    de usuarios). Si un profesor no tiene número guardado, el aviso
--    de WhatsApp simplemente no se muestra para sus clases.
--
-- 2) reservar_franja_v2 ahora también devuelve "profesorWhatsapp"
--    (buscando el whatsapp del profesor por su correo en
--    staff_usuarios) además de "profesor" (su correo), para que
--    agendar-clase.html pueda armar el aviso de WhatsApp específico
--    de ese profesor.
--
-- 3) Se agrega un manejador de errores: si algo falla de forma
--    inesperada dentro de la función, en vez de devolver un error
--    genérico ahora se devuelve el motivo real (ok:false + el
--    mensaje de Postgres), para poder diagnosticar más rápido.
-- ============================================================

alter table staff_usuarios add column if not exists whatsapp text;

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
  v_whatsapp text;
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

  select whatsapp into v_whatsapp
  from staff_usuarios
  where email = v_franja.profesor
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'plataforma', v_franja.plataforma,
    'fecha', v_franja.fecha,
    'hora', v_franja.hora,
    'profesor', v_franja.profesor,
    'profesorWhatsapp', v_whatsapp,
    'nombre', v_cliente.nombre
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', 'Error interno: ' || sqlerrm);
end;
$$;

grant execute on function public.reservar_franja_v2(uuid, text, text) to anon;
