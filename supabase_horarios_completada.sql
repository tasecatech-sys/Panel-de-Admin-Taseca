-- ============================================================
-- Taseca · Marcar clases realizadas y reagendar
-- Ejecuta esto en: Supabase Dashboard > SQL Editor > New query
-- ============================================================
-- Agrega la columna "completada" a "horarios": permite marcar desde
-- el panel (Plan de Estudio > Horarios, detalle de un día) que una
-- clase reservada ya se llevó a cabo. No afecta franjas existentes
-- (quedan en false / "no realizada" por defecto).
--
-- "Reagendar" no necesita SQL nuevo: reutiliza estado='libre' y
-- estado='reservada', que ya existen en la tabla.
-- ============================================================

alter table horarios add column if not exists completada boolean not null default false;
