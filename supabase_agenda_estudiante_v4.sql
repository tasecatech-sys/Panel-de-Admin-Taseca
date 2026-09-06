-- ============================================================
-- Taseca · Reserva de franja a prueba de restricciones (v4)
-- Ejecuta esto en: Supabase Dashboard > SQL Editor > New query
-- ============================================================
-- Por qué este archivo: "reservar_franja_v2" venía fallando con
--   "new row for relation horarios violates check constraint
--    horarios_estado_check"
-- porque asumía que el valor para "reservado" era el texto
-- 'reservada', y tu tabla "horarios" tiene una restricción (CHECK)
-- que exige otra palabra distinta (no sabemos cuál desde aquí sin
-- consultar tu base de datos).
--
-- En vez de seguir adivinando la palabra exacta, esta versión
-- prueba automáticamente una lista de valores comunes
-- ('reservada', 'reservado', 'ocupada', 'ocupado', 'confirmada',
-- 'confirmado', 'tomada', 'tomado', 'agendada', 'agendado') y usa
-- el primero que tu base de datos acepte. Una vez encontrado, lo
-- imprime en el resultado (campo "estadoUsado") para que quede
-- registrado cuál es.
-- ============================================================

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
  v_candidatos text[] := array[
    'reservada','reservado','ocupada','ocupado','confirmada','confirmado',
    'tomada','tomado','agendada','agendado','no_disponible','completa','completo'
  ];
  v_valor text;
  v_usado text := null;
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

  -- Prueba cada valor candidato dentro de su propio "savepoint": si
  -- la restricción lo rechaza, se descarta ese intento y se sigue
  -- con el siguiente, sin afectar el resto de la función.
  foreach v_valor in array v_candidatos loop
    begin
      update horarios set estado = v_valor, cliente_id = v_cliente.id where id = p_franja_id;
      v_usado := v_valor;
      exit;
    exception when check_violation then
      -- este valor no es válido para tu restricción; se intenta el siguiente
      null;
    end;
  end loop;

  if v_usado is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'Ninguno de los valores de estado conocidos fue aceptado por la base de datos. Copia este mensaje y compártelo para revisar la restricción "horarios_estado_check" manualmente.'
    );
  end if;

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
    'nombre', v_cliente.nombre,
    'estadoUsado', v_usado
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', 'Error interno: ' || sqlerrm);
end;
$$;

grant execute on function public.reservar_franja_v2(uuid, text, text) to anon;
