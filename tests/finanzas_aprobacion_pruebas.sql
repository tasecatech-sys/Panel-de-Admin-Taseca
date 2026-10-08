-- Pruebas de supabase_finanzas_aprobacion.sql (entorno local con roles simulados; NO correr en producción).
\set ON_ERROR_STOP 1
-- históricos aprobados
do $$ begin assert (select count(*) from fin_movimientos where estado='aprobado' and aprobado_por='histórico')=2, 'históricos aprobados'; end $$;
insert into staff_usuarios(email,nombre,rol) values ('aprob@t.co','Aprobador','aprobador');
create or replace function t_as(e text) returns void language plpgsql as $$ begin perform set_config('request.jwt.claims', json_build_object('email',e)::text, true); end $$;
grant execute on function t_as(text) to authenticated;

-- ADMIN crea → pendiente aunque intente aprobado
begin; set local role authenticated; select t_as('admin@t.co');
insert into fin_movimientos(id,tipo,concepto,monto,metodo_pago,estado,aprobado_por) values ('11111111-1111-1111-1111-111111111111','gasto','arriendo',800000,'Transferencia','aprobado','admin@t.co');
do $$ begin assert (select estado from fin_movimientos where id='11111111-1111-1111-1111-111111111111')='pendiente', 'A1 nace pendiente'; end $$;
-- admin intenta aprobar → ignorado
update fin_movimientos set estado='aprobado' where id='11111111-1111-1111-1111-111111111111';
do $$ begin assert (select estado from fin_movimientos where id='11111111-1111-1111-1111-111111111111')='pendiente', 'A2 admin no aprueba'; end $$;
commit;

-- APROBADOR ve y aprueba; no puede cambiar monto, ni crear, ni borrar
begin; set local role authenticated; select t_as('aprob@t.co');
do $$ begin assert (select count(*) from fin_movimientos)=3, 'B1 aprobador ve movimientos'; assert (select count(*) from fin_prestamos)=1, 'B1 ve prestamos'; end $$;
update fin_movimientos set estado='aprobado' where id='11111111-1111-1111-1111-111111111111';
do $$ begin assert (select estado||'|'||aprobado_por from fin_movimientos where id='11111111-1111-1111-1111-111111111111')='aprobado|aprob@t.co', 'B2 aprobado con firma'; end $$;
commit;
begin; set local role authenticated; select t_as('aprob@t.co');
do $$ begin begin update fin_movimientos set monto=1 where id='11111111-1111-1111-1111-111111111111'; raise exception 'NO_DEBIA'; exception when others then if sqlerrm='NO_DEBIA' then raise; end if; end; end $$;
do $$ begin begin insert into fin_movimientos(tipo,monto) values ('ingreso',5); raise exception 'NO_DEBIA'; exception when others then if sqlerrm='NO_DEBIA' then raise; end if; end; end $$;
do $$ begin begin update fin_movimientos set estado='rechazado' where id='11111111-1111-1111-1111-111111111111'; raise exception 'NO_DEBIA'; exception when others then if sqlerrm='NO_DEBIA' then raise; end if; end; end $$;
delete from fin_movimientos where id='11111111-1111-1111-1111-111111111111'; -- RLS: no borra nada
do $$ begin assert (select count(*) from fin_movimientos where id='11111111-1111-1111-1111-111111111111')=1, 'B3 aprobador no borra'; end $$;
do $$ begin begin update fin_prestamos set capital=1; exception when others then null; end; assert (select capital from fin_prestamos limit 1)=1000, 'B4 prestamos solo lectura'; end $$;
commit;

-- ADMIN: no borra aprobado; editar monto → vuelve a pendiente; editar notas → sigue aprobado
begin; set local role authenticated; select t_as('admin@t.co');
do $$ begin begin delete from fin_movimientos where id='11111111-1111-1111-1111-111111111111'; raise exception 'NO_DEBIA'; exception when others then if sqlerrm='NO_DEBIA' then raise; end if; end; end $$;
update fin_movimientos set notas='factura #12' where id='11111111-1111-1111-1111-111111111111';
do $$ begin assert (select estado from fin_movimientos where id='11111111-1111-1111-1111-111111111111')='aprobado', 'C1 notas no reabren'; end $$;
update fin_movimientos set monto=850000 where id='11111111-1111-1111-1111-111111111111';
do $$ begin assert (select estado||'|'||coalesce(aprobado_por,'-') from fin_movimientos where id='11111111-1111-1111-1111-111111111111')='pendiente|-', 'C2 monto reabre'; end $$;
commit;

-- APROBADOR rechaza con motivo → ADMIN puede borrar
begin; set local role authenticated; select t_as('aprob@t.co');
update fin_movimientos set estado='rechazado', motivo_rechazo='sin soporte' where id='11111111-1111-1111-1111-111111111111';
commit;
begin; set local role authenticated; select t_as('admin@t.co');
delete from fin_movimientos where id='11111111-1111-1111-1111-111111111111';
do $$ begin assert (select count(*) from fin_movimientos where id='11111111-1111-1111-1111-111111111111')=0, 'D1 admin borra rechazado'; end $$;
commit;

-- PROFESOR no ve nada
begin; set local role authenticated; select t_as('profe@t.co');
do $$ begin assert (select count(*) from fin_movimientos)=0, 'E1 profesor no ve'; end $$;
commit;
\echo '✅ PRUEBAS DE APROBACIÓN OK'
