# Sincronización automática con Google Calendar

Cada cita que se guarda en Supabase aparece sola en el Google Calendar de Taseca, con recordatorios 24 h / 1 h / 15 min y un enlace de Meet si la clase es Virtual. Si la cita cambia, el evento se actualiza. Si se cancela, el evento se elimina. El panel y la página de agendamiento no se modificaron, y el aviso de WhatsApp sigue funcionando igual.

---

## 1. Cómo funciona

```
Panel (Agenda / Plan de Estudio)      agendaclases.taseca.tech
              │  INSERT / UPDATE / DELETE      │ reservar_franja_v2
              ▼                                ▼
        tabla horarios                   tabla agenda
              │  trigger gcal_sync_*  (misma transacción)
              ▼
   tabla gcal_sync  ← mapa "cita → evento" + cola de pendientes
              │  pg_net (asíncrono, después del commit)
              ▼
   Edge Function gcal-sync   (secretos aquí; usa service_role)
              │  POST + TOKEN
              ▼
   Google Apps Script Web App (corre como la cuenta Taseca)
              ▼
   Google Calendar de Taseca → recordatorios → tu celular

   pg_cron (red de seguridad):
     cada 10 min → reintenta pendientes/errores
     cada hora   → busca citas próximas sin sincronizar
     cada 6 h    → re-verifica las próximas 2 semanas contra Google
```

### Qué cuenta como "cita"

| Tabla | Es cita activa cuando… | Se cancela el evento cuando… |
|---|---|---|
| `horarios` | `estado <> 'libre'` **y** `cliente_id` no es nulo | la franja vuelve a `libre` (botón **Reagendar**) o se elimina |
| `agenda` | `estado <> 'Cancelada'` (Programada y Completada conservan el evento) | `estado = 'Cancelada'` o se pulsa **Eliminar** |

Al **Reagendar** en Plan de Estudio, el panel libera la franja vieja y reserva *otra fila*. Por eso se cancela un evento y se crea otro, lo cual es correcto: son dos franjas distintas.

Esta regla está escrita **una sola vez**, en la vista `gcal_citas`. Si mañana quieres excluir, por ejemplo, las "Demo", basta con cambiar esa vista.

### Por qué esta arquitectura

- **Trigger propio + pg_net, en lugar de "Database Webhook" del dashboard.** Un webhook solo hace una llamada HTTP: si Google no responde, la cita se queda sin evento y nadie se entera. El trigger primero anota la cita en `gcal_sync` dentro de la misma transacción (patrón *outbox*), así que el estado "existe en Supabase pero no en Google" siempre queda registrado. Por debajo, los Database Webhooks también usan pg_net.
- **Por qué hay una Edge Function intermedia.** Guarda el token del Apps Script y la service_role. Nada de esto llega al navegador.
- **Por qué Apps Script.** Corre con la cuenta de Google de Taseca, así que no hay que manejar OAuth, refresh tokens ni cuentas de servicio. Usa el servicio avanzado *Calendar API v3*, que permite recordatorios personalizados, etiquetas ocultas para encontrar el evento y Google Meet.
- **Si algo falla, la reserva nunca falla.** Todo el código de los triggers está envuelto en `exception`, así que la reserva del estudiante o la edición en el panel siempre se guardan.

### Anti-duplicados (tres capas)

1. `gcal_sync` tiene la clave primaria `(origen, registro_id)`: una cita tiene una sola fila.
2. `gcal_sync_reclamar` usa `FOR UPDATE SKIP LOCKED` más un bloqueo de 3 min, así que dos procesos nunca toman la misma cita a la vez.
3. Cada evento lleva la etiqueta oculta `tasecaRef = horarios:<uuid>`. Antes de crear un evento, Apps Script busca esa etiqueta, así que aunque Supabase pierda el `event_id` no se crea un segundo evento. Si encuentra duplicados de antes, deja uno solo. Además, `LockService` atiende las peticiones de una en una.

---

## 2. Archivos

| Archivo | Qué es |
|---|---|
| `supabase_gcal_sync.sql` | Tabla, vistas, triggers, cola y cron (**nuevo**) |
| `supabase/functions/gcal-sync/index.ts` | Edge Function (**nueva**) |
| `google-apps-script/Code.gs` + `appsscript.json` | Web App de Google (**nueva**) |
| `tests/gcal_sync_pruebas.sql` | Pruebas de la base de datos (terminan en ROLLBACK) |
| `tests/gcal_sync_edge_test.ts` | Pruebas unitarias de la Edge Function |

`admin-taseca.html`, `agendar-clase.html` y las funciones SQL existentes **no se tocaron**.

---

## 3. Configuración paso a paso

Antes de empezar, genera **dos secretos** distintos y guárdalos en un lugar temporal:

- `GCAL_SYNC_SECRET`: lo comparten Supabase Vault y la Edge Function. Puede ser cualquier texto aleatorio largo, por ejemplo la salida de `openssl rand -hex 32` o dos UUID pegados.
- `TOKEN` del Apps Script: lo genera el propio script en el paso A4.

### A. Google Apps Script y Google Calendar (con la cuenta de Taseca)

1. Entra a <https://script.google.com> con la cuenta de Google **de Taseca**, la dueña del calendario donde quieres los eventos. Crea un proyecto nuevo llamado `Taseca GCal Sync`.
2. Ve a **Configuración del proyecto** (engranaje) y marca *"Mostrar el archivo de manifiesto appsscript.json"*. Vuelve al **Editor**, abre `appsscript.json` y reemplaza su contenido por el de `google-apps-script/appsscript.json`. Este archivo ya activa el servicio avanzado **Google Calendar API** y fija la zona `America/Bogota`.
3. Abre `Código.gs` y reemplázalo por el contenido de `google-apps-script/Code.gs`. Guarda.
4. En el selector de funciones elige **`generarToken`** y pulsa **Ejecutar**. Google pedirá permisos de Calendar: acéptalos con la cuenta de Taseca. Si sale "app no verificada", ve a *Configuración avanzada → Ir a Taseca GCal Sync*; es normal en scripts propios. Copia el token que aparece en el **Registro de ejecución**.
5. *(Recomendado)* Ejecuta **`probarIntegracion`**. Esta prueba crea, actualiza y cancela un evento de prueba para mañana. El registro debe mostrar `creado → sin_cambios (mismo id) → actualizado → cancelado → no_existia`.
6. Pulsa **Implementar → Nueva implementación** y elige el tipo **Aplicación web** con:
   - *Ejecutar como*: **Yo** (cuenta Taseca)
   - *Quién tiene acceso*: **Cualquier persona**. Es necesario para que Supabase pueda llamarla, y la protege el TOKEN.

   Copia la **URL que termina en `/exec`**.
7. **Calendario**: por defecto se usa el calendario principal de la cuenta (`CALENDAR_ID: 'primary'`). Si prefieres un calendario aparte, por ejemplo "Clases Taseca", créalo en Google Calendar, copia su *ID del calendario* (en Configuración del calendario) y ponlo en `CONFIG.CALENDAR_ID`.
8. **Recordatorios en tu celular**: instala la app Google Calendar e inicia sesión con la cuenta de Taseca, con las notificaciones activadas. Los recordatorios de cada evento ya vienen configurados; no dependen de los valores por defecto de tu calendario.

> Cada vez que cambies `Code.gs`, ve a **Implementar → Administrar implementaciones → editar (lápiz) → Versión: Nueva versión**. Así la URL `/exec` no cambia.

### B. Supabase

1. **Extensiones**: en *Database → Extensions*, habilita **pg_net** y **pg_cron**.
2. **Edge Function**: en *Edge Functions → Deploy a new function*, nómbrala exactamente `gcal-sync` y pega `supabase/functions/gcal-sync/index.ts`. En los ajustes de la función, **desactiva "Verify JWT"**. La función se protege con su propio secreto `x-sync-secret`.
3. **Secretos de la Edge Function** (*Project Settings → Edge Functions → Secrets*):

   | Nombre | Valor |
   |---|---|
   | `GCAL_SYNC_SECRET` | tu secreto largo aleatorio |
   | `APPS_SCRIPT_URL` | la URL `/exec` del paso A6 |
   | `APPS_SCRIPT_TOKEN` | el token del paso A4 |
   | `PANEL_URL` | *(opcional)* `https://panel-de-admin-taseca.vercel.app` |
   | `GCAL_INVITAR_PROFESOR` | *(opcional)* `true` para invitar al profesor |
   | `GCAL_INVITAR_ESTUDIANTE` | *(opcional)* `true` para invitar al estudiante |

4. **SQL**: en *SQL Editor → New query*, pega y ejecuta **`supabase_gcal_sync.sql`** completo. Puedes correrlo varias veces sin problema.
5. **Vault** (una sola vez, en el SQL Editor; reemplaza los valores):
   ```sql
   select vault.create_secret('https://<TU-PROJECT-REF>.supabase.co/functions/v1/gcal-sync', 'gcal_sync_url');
   select vault.create_secret('<EL MISMO GCAL_SYNC_SECRET>', 'gcal_sync_secret');
   ```
   El project ref actual es el subdominio de `SUPABASE_URL` en el panel: `mzxyqkbhrcegiyqbbazp`. Si después quieres cambiar un valor, usa `select vault.update_secret((select id from vault.secrets where name='gcal_sync_secret'), '<nuevo>');`.
6. **Probar la conexión Supabase → Apps Script → Google:**
   ```bash
   curl -X POST https://mzxyqkbhrcegiyqbbazp.supabase.co/functions/v1/gcal-sync \
     -H "x-sync-secret: <GCAL_SYNC_SECRET>" -H "Content-Type: application/json" \
     -d '{"modo":"ping"}'
   ```
   Si todo está bien, responde `{"ok":true,"appsScript":{"ok":true,"accion":"pong",…}}`.
7. **Sincronización inicial** de las citas futuras que ya existen:
   ```sql
   select public.gcal_sync_reconciliar(60, false);   -- próximos 60 días
   select public.gcal_sync_disparar();
   ```
8. **Pruebas de base de datos**: ejecuta `tests/gcal_sync_pruebas.sql` en el SQL Editor. No deja datos. Al final debe salir `✅ TODAS LAS PRUEBAS PASARON`.

### C. Cambiar la configuración después

| Quiero… | Dónde |
|---|---|
| Otros recordatorios | `CONFIG.RECORDATORIOS` en `Code.gs`. Admite hasta 5, con `popup` o `email`. Luego publica una nueva versión. Los eventos existentes se actualizan en la siguiente verificación de 6 h, o enseguida si ejecutas `select gcal_sync_reconciliar(60,true); select gcal_sync_disparar();` |
| Apagar Meet | `CONFIG.MEET_HABILITADO = false` |
| Otro calendario | `CONFIG.CALENDAR_ID` |
| Colores | `CONFIG.COLOR_POR_ORIGEN` (IDs 1–11 de Google) |
| Invitar profesor o estudiante | secretos `GCAL_INVITAR_*` de la Edge Function |
| Qué cuenta como cita | vista `gcal_citas` en `supabase_gcal_sync.sql` |
| Frecuencia del cron | *Integrations → Cron* en Supabase, o `cron.schedule(...)` al final del SQL |

---

## 4. Google Meet

Sí se puede, y ya está incluido **solo para citas Virtuales**:

- Se usa `conferenceData.createRequest` (`hangoutsMeet`) del servicio avanzado Calendar API. No requiere APIs de pago ni una cuenta de servicio, solo el permiso de Calendar que aceptaste en el paso A4.
- Funciona con cuentas Gmail normales. Si Taseca usa Google Workspace, el administrador debe tener Meet habilitado para la cuenta.
- El enlace queda en el evento y además se guarda en `gcal_sync.meet_url`, por si después quieres mostrarlo en el panel o enviarlo por WhatsApp.
- Si una cita cambia de Virtual a Presencial, el Meet ya creado se conserva, porque quitarlo podría romper un enlace que ya compartiste.

---

## 5. Supervisión y recuperación

```sql
-- Todas las citas próximas y su estado de sincronización
select * from gcal_sync_estado;

-- Solo lo que NO está bien
select * from gcal_sync_estado where estado_sync not in ('sincronizado');

-- Forzar todo ahora (por ejemplo, después de una caída de Google)
select gcal_sync_reconciliar(30, true);
select gcal_sync_disparar();

-- Respuestas recientes de la Edge Function (pg_net)
select id, status_code, left(content::text, 200), created from net._http_response order by id desc limit 10;
```

| `estado_sync` | Significa |
|---|---|
| `sincronizado` | El evento existe en Google y coincide con la cita |
| `pendiente` | Se va a procesar en segundos o, como mucho, en el siguiente ciclo de 10 min |
| `error` | Google o Apps Script falló. Mira `ultimo_error`. Se reintenta solo, con espera creciente (2, 4, 8 … hasta 60 min) |
| `cancelado` | La cita se canceló y el evento se eliminó |
| `sin_sincronizar` | La cita existe pero no está en la cola (por ejemplo, si el trigger falló). La reconciliación de cada hora la recoge |

Errores típicos en `ultimo_error`:

- `[NO_AUTORIZADO]`: `APPS_SCRIPT_TOKEN` no coincide con la propiedad `TOKEN` del script.
- `RESPUESTA_NO_JSON … HTTP 401/403`: la Web App no está publicada como "Cualquier persona", o la URL no es la `/exec`.
- `Faltan los secretos APPS_SCRIPT_URL…`: faltan secretos en la Edge Function.
- WARNING `faltan los secretos gcal_sync_url…` en los logs de Postgres: faltó el paso B5 (Vault).

---

## 6. Pruebas

### Automáticas (ya ejecutadas en el entorno de desarrollo)

- `tests/gcal_sync_pruebas.sql`: 11 grupos de pruebas sobre la base de datos (encolado, cambios irrelevantes, mapeo, concurrencia, carrera, error, reintento, cancelación, agenda, recuperación).
- `tests/gcal_sync_edge_test.ts`: construcción del evento (horas, duración, Meet, medianoche, datos inválidos). Se ejecuta con `GCAL_SYNC_TEST=1 deno test --allow-env --allow-net tests/gcal_sync_edge_test.ts`.
- Prueba de punta a punta con Postgres, PostgREST, la Edge Function y el `Code.gs` real ejecutado contra un Google Calendar simulado. Cubrió todos los casos de la tabla de abajo y además 10 llamadas simultáneas, que dieron como resultado un solo evento.

### Manuales en producción (checklist)

| # | Caso | Cómo | Resultado esperado |
|---|---|---|---|
| 1 | Crear cita | Agenda una clase Virtual desde agendaclases o el panel | En unos segundos aparece el evento "Clase Power BI · Nombre" a la hora correcta, con Meet y 3 recordatorios |
| 2 | Cita duplicada | Ejecuta `select gcal_sync_reconciliar(14,true); select gcal_sync_disparar();` dos veces | Sigue habiendo **un** evento; `ultima_accion = sin_cambios` |
| 3 | Modificar | Cambia la hora o la duración en Agenda | El **mismo** evento se mueve; no aparece otro |
| 4 | Cancelar | Pon estado *Cancelada* en Agenda, o usa *Reagendar* en Plan de Estudio | El evento desaparece del calendario (y en Reagendar aparece el nuevo) |
| 5 | Error de Google | En Edge Function Secrets cambia `APPS_SCRIPT_TOKEN` por uno inválido y crea una cita | La cita se guarda normal; `gcal_sync_estado` muestra `error` con `[NO_AUTORIZADO]` |
| 6 | Reintento | Restaura el token correcto | En ≤ 10 min (o al ejecutar `select gcal_sync_disparar();` tras poner `proximo_intento_at = now()`) pasa a `sincronizado` |
| 7 | Ya sincronizada | Edita solo "completada" (✓ Realizada) | No cambia nada en Google (`version` no sube) |
| 8 | Borrado manual en Google | Borra un evento a mano en Google Calendar | En la siguiente verificación de 6 h, o forzándola, se recrea |
| 9 | WhatsApp | Agenda desde agendaclases | El botón "Avisar por WhatsApp" sigue apareciendo igual |

---

## 7. Notas de seguridad y privacidad

- El navegador nunca ve el token de Apps Script, la URL de la Web App ni la service_role: viven en los secretos de la Edge Function y en Vault.
- `gcal_sync` tiene RLS activado: los usuarios del panel solo pueden **leerla**, y `anon` no tiene acceso. Las funciones de la cola solo las puede ejecutar `service_role`.
- La descripción del evento incluye el nombre, documento, correo y teléfono del estudiante, y queda en el calendario privado de Taseca. Si compartes ese calendario con otras personas, considera quitar esos campos en `construirEvento` (Edge Function).
- Por defecto **no** se invita a nadie, así que Google no envía correos a estudiantes ni a profesores.

## 8. Limitaciones conocidas

- La definición de la tabla `horarios` no está en el repo, porque se creó aparte. El código no asume tipos (`fecha` puede ser `date` o `text`, `duracion` número o texto) y usa los mismos valores de `estado` que ya usa el panel (`'libre'` / no libre).
- Apps Script tiene cuotas diarias (miles de eventos al día en cuentas Gmail), muy por encima del volumen de Taseca.
- Si editas un evento a mano en Google, la próxima verificación lo devuelve a lo que diga Supabase, porque **Supabase es la fuente de verdad**. Los cambios se hacen en el panel.
