# Guion de defensa — 15 minutos, dos personas (A y B)

Preparación antes de empezar: `docker compose up -d` desde cero, esperar a
que `pg-master`, `pg-replica`, `pg-norte`, `pg-sur`, `api` y `web` estén
`Up`/`healthy` (`docker compose ps`). Tener tres paneles de terminal
visibles: uno para `pg-master`/`pg-replica`, otro para `docker logs api -f`,
otro libre para ejecutar comandos. Cargar `http://localhost:8090` en el
navegador (o el puerto configurado en `WEB_PORT`).

Variables de entorno cargadas en la terminal de comandos (una sola vez):
```bash
cd globalhealth
set -a; source .env; set +a
```

---

## 0:00–1:30 — Caso de negocio y arquitectura (persona A)

Sin comandos: explicar el caso GlobalHealth (red de clínicas
centroamericanas), por qué la arquitectura es híbrida (MOR para personal y
clínicas, XML/XSD para expedientes regulados, MongoDB para telemetría de
alto volumen), y mostrar el diagrama de `docs/01_arquitectura.md`.

## 1:30–4:30 — MOR en vivo: tipos, herencia, tabla tipada, método, CRUD (A)

```bash
docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -c "\d clinica"

docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -c \
  "SELECT count(*) FROM ONLY persona; SELECT count(*) FROM persona;"

docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -c \
  "SELECT nombre_completo(m.*), especialidad_principal(m.*) FROM medico m;"
```

Explicar: `CREATE TABLE ... OF` vs `INHERITS` (incompatibles, por eso
`clinica` es tipada y la jerarquía de personal usa herencia). Mostrar
`sql/03_mor_crud.sql` en el editor para el UPDATE de un atributo anidado
(`SET direccion.ciudad = ...`) y de un elemento de arreglo.

## 4:30–7:00 — XML: registrar XSD, insertar válido/inválido, xmltable (B)

```bash
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" \
  -f /dev/stdin < xml/samples/insertar_muestras.sql
```

Señalar en la salida: los 3 `ACEPTADO`, los 4 `RECHAZADO` con el mensaje
exacto de `lxml`, el rechazo del documento v1 contra el esquema v2
recién actualizado, y el bloqueo de `eliminar_xsd` por documentos
dependientes. Después:

```bash
docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -c \
  "SELECT ec.id, d.* FROM expediente_clinico ec,
     XMLTABLE(XMLNAMESPACES('urn:globalhealth:expediente:v1' AS gh),
       '/gh:expediente/gh:diagnosticos/gh:diagnostico' PASSING ec.documento
       COLUMNS codigo text PATH 'gh:codigo', descripcion text PATH 'gh:descripcion'
     ) AS d LIMIT 5;"
```

## 7:00–9:00 — MongoDB Atlas: jerarquía y \$lookup en vivo (B)

```bash
docker run --rm mongo:7 mongosh \
  "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" --quiet --eval '
  db.sensor_logs.aggregate([
    { $match: { alerta: true } }, { $limit: 3 },
    { $lookup: { from: "sesiones", let: { s: "$sesion_id" },
        pipeline: [ { $match: { $expr: { $eq: ["$_id", "$$s"] } } },
          { $lookup: { from: "pacientes", localField: "paciente_id", foreignField: "_id", as: "paciente" } },
          { $unwind: "$paciente" } ],
        as: "sesion" } },
    { $unwind: "$sesion" }
  ]).forEach(printjson)'
```

Explicar el criterio referencia vs. embebido: `sensor_logs` por referencia
(crece sin límite, riesgo de 16 MB por documento), `signos_vitales_resumen`
y `notas` embebidos (baja cardinalidad, se leen junto con la sesión).

## 9:00–11:30 — CAOS: caída y recuperación del master (A)

```bash
curl -s http://localhost:3000/health; echo
docker stop pg-master
curl -s -o /dev/null -w "GET /api/dashboard/resumen -> HTTP %{http_code}\n" \
  http://localhost:3000/api/dashboard/resumen
curl -s -o /dev/null -w "POST /api/personal -> HTTP %{http_code}\n" \
  -X POST http://localhost:3000/api/personal -H "Content-Type: application/json" \
  -d '{"tipo":"enfermero","nombre":"Demo","apellido":"Caos","fecha_nacimiento":"1990-01-01","documento_identidad":"0-0000-0000","turno":"nocturno","unidad":"Demo"}'
curl -s http://localhost:3000/health; echo
docker start pg-master
sleep 5
docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -c \
  "SELECT client_addr, state FROM pg_stat_replication;"
```

Señalar: la lectura sigue en 200, la escritura da 503 con mensaje claro (no
un crash del backend), `/health` reporta los tres nodos por separado, y la
replicación se restablece sola sin ningún comando manual de reparación.
Si el profesor pide ver el failover real: `docker exec pg-replica psql -U
postgres -c "SELECT pg_promote();"` (ensayado de antemano, no improvisar en
vivo la primera vez).

## 11:30–13:00 — Fragmentación: EXPLAIN + reconstrucción vertical (B)

```bash
docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -c \
  "EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM paciente_global WHERE region = 'SUR';"

docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-norte \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGNORTE_DB" -c \
  "SET ROLE dashboard_ro; SELECT * FROM paciente_publico;"
docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-norte \
  psql -U "$POSTGRES_SUPERUSER" -d "$PGNORTE_DB" -c \
  "SET ROLE dashboard_ro; SELECT * FROM paciente_financiero;"
```

Señalar: un solo `Foreign Scan` (partition pruning) cuando se filtra por
región, y el `permission denied` esperado del rol de solo lectura sobre
los datos financieros.

## 13:00–15:00 — Costo/beneficio y cierre (ambos)

Mostrar `docs/03_costo_beneficio.md`: TCO a 12 meses, punto de equilibrio,
riesgos (vendor lock-in, soberanía de datos médicos). Cerrar con la tesis
del proyecto: cada capa usa el modelo de consistencia que le corresponde
(ACID para personal/expedientes, BASE para telemetría de sensores) — no
por dogma, sino porque el costo de perder un diagnóstico y el costo de
perder una lectura de sensor no son el mismo costo.
