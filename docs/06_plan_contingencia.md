# Plan de contingencia — defensa en vivo

Cada escenario con su comando de recuperación y su alternativa de
respaldo. Tener este archivo abierto en una pestaña durante la defensa.

## 1. Falla el wifi / no hay Internet en el aula

**Afecta:** MongoDB Atlas (Fase 4) y `docker run mongo:7 ...` si la imagen
no está cacheada localmente.

**Recuperación:**
- Confirmar que `mongo:7` ya está descargado en la laptop (`docker images
  | grep mongo`) — descargarlo ANTES de entrar al aula, no depender del
  wifi del aula.
- Si el wifi cae a mitad de demo, PostgreSQL (MOR, XML, replicación,
  fragmentación) sigue funcionando 100% local, sin red externa: seguir la
  demo con esos bloques primero y volver a Mongo si se recupera la
  conexión.

**Respaldo:** capturas de pantalla de `mongo/03_queries_agregacion.js`
corriendo exitosamente contra Atlas (tomarlas ANTES de la defensa, con
fecha visible), más un dump exportado con `mongoexport` de las
colecciones para poder mostrar los datos aunque sea sin conexión en vivo.

## 2. Atlas no responde (cluster pausado, IP Access List desactualizada)

**Recuperación:**
- Verificar Network Access en Atlas: confirmar que la IP del aula está en
  la Access List (o que `0.0.0.0/0` sigue habilitado si se dejó así a
  propósito para la demo).
- `docker run --rm mongo:7 mongosh "$MONGODB_URI" --eval "db.runCommand({ping:1})"`
  para diagnosticar rápido si es problema de red o de cluster pausado.
- Si el cluster M0 se pausó por inactividad, reanudarlo desde el panel de
  Atlas (tarda 1–3 minutos) — avisar al profesor que se está reanudando en
  vivo, es parte legítima de la demo de cloud real.

**Respaldo:** igual que el escenario 1 — capturas + dump exportado.

## 3. Un contenedor no levanta

**Recuperación general:**
```bash
docker compose logs <servicio> --tail 50
```
- **pg-replica no arranca:** casi siempre es que `pg-master` no estaba
  `healthy` cuando la réplica intentó `pg_basebackup`. Ver sección 4.
- **api no arranca:** revisar que `.env` tenga todas las variables
  (`docker compose config` para verlas resueltas); un `MONGODB_URI` vacío
  hace que el healthcheck de Atlas falle pero NO debería tumbar el
  proceso — si sí lo tumba, es un bug a corregir antes de la defensa, no
  algo a improvisar en el momento.
- **pg-norte / pg-sur no arrancan:** revisar puertos 5434/5435 libres en
  el host (`netstat -ano | grep 543`), igual que el problema de 5432 con
  un PostgreSQL nativo documentado en este mismo proyecto.

**Respaldo:** `scripts/reset_demo.sh` reconstruye todo desde cero en un
solo comando (ver advertencia de que borra volúmenes antes de correrlo).

## 4. `pg_basebackup` falla al inicializar la réplica

**Causas típicas y su fix:**
- `PGDATA` de la réplica no estaba vacío: el volumen `pgreplica_data` ya
  tenía datos de un intento anterior. `docker volume rm
  proyectofinalbasesdedatos_pgreplica_data` (con el contenedor detenido) y
  reintentar.
- El rol `replicador` o el `replication slot` no existen en el maestro
  (`init-master.sh` no corrió, o corrió antes de que `PG_REPLICATION_USER`
  estuviera bien seteado en `.env`): verificar con
  `SELECT * FROM pg_replication_slots;` en el maestro.
- El maestro no estaba `healthy` cuando la réplica lo intentó contactar:
  la réplica reintenta con `pg_isready` en un loop, pero si el maestro
  tarda demasiado en levantar (primera vez, construyendo la imagen),
  puede valer la pena reiniciar solo el contenedor de la réplica:
  `docker compose restart pg-replica`.

**Respaldo:** tener un `docker save`/`docker load` de las imágenes ya
construidas (`postgres` custom, `api`, `mongo:7`) en un pendrive, para no
depender de reconstruir todo desde cero si el aula tiene mala conexión
para `docker build`/`apt-get`.

## 5. El puerto 5432 (o 8080) del host está ocupado por otro proceso

Ya nos pasó en desarrollo: un PostgreSQL nativo de Windows escuchando en
el mismo puerto 5432 que Docker publica, causando errores de
autenticación confusos (parecía credencial incorrecta, pero en realidad
el cliente se conectaba al proceso equivocado). Si pasa en el aula:
- `netstat -ano | grep :5432` (Windows) o `lsof -i :5432` (Mac/Linux) para
  identificar el proceso.
- Cambiar el mapeo de puerto en `.env`/`docker-compose.yml` a otro puerto
  libre (el contenedor sigue escuchando internamente en 5432/80; solo
  cambia el puerto publicado al host) y usar `docker exec` para los
  comandos de la demo en vez de depender del puerto del host — es lo que
  se hizo en `sql/07_frag_horizontal.sql` y `08_frag_vertical.sql`
  precisamente para evitar este problema.

## Checklist de "portátil con todo local" antes de entrar al aula

- [ ] `docker compose down -v && docker compose up -d` corrido una vez
      completo desde cero, sin errores.
- [ ] Imagen `mongo:7` ya descargada (`docker images`).
- [ ] `.env` completo y correcto (no `.env.example`).
- [ ] Capturas de pantalla de cada demo funcionando, guardadas fuera del
      repo (por si hay que mostrar evidencia sin poder ejecutar nada en
      vivo).
- [ ] `scripts/verify_all.sh` corrido y en verde la noche anterior.
- [ ] Wifi del aula probado con anticipación; plan de que Postgres no
      depende de él, solo Mongo Atlas.
