# PLAN DE EJECUCIÓN POR FASES — Proyecto Final Integrador
## "GlobalHealth Unified System" — Bases de Datos Avanzadas

---

## 0. Decisiones de arquitectura

### 0.1 Stack elegido (y por qué)

| Capa | Tecnología | Justificación defendible ante el profesor |
|---|---|---|
| MOR (Objeto-Relacional) | **PostgreSQL 16** | Soporta tipos compuestos (`CREATE TYPE`), tablas tipadas (`CREATE TABLE ... OF`), herencia de tablas (`INHERITS`), arreglos de tipos compuestos (equivalente a *nested tables*) y notación funcional `objeto.metodo()`. |
| XML + XSD | **PostgreSQL 16 + PL/Python3u + lxml** | Se registra el XSD **dentro de la BD** (tabla catálogo `xsd_registry`) y la validación se ejecuta **en el motor** vía trigger. Cumple la cláusula anti-plagio: no se puede insertar XML plano sin pasar por el XSD registrado. |
| NoSQL | **MongoDB Atlas (cluster real en la nube)** | Cumple simultáneamente Unidad I (modelo documental) y Unidad II (cloud computing). |
| Replicación | **Streaming Replication nativa de PostgreSQL** en 2 contenedores Docker | Replicación física real Maestro→Esclavo; el esclavo es read-only por diseño del motor, no simulado. |
| Fragmentación | **postgres_fdw + particionamiento declarativo** en nodos separados | Los fragmentos horizontales viven en contenedores distintos y se reconstruyen desde un coordinador. |
| Backend | **Node.js + Express** (o FastAPI si prefieren Python) | Debe tener **dos pools de conexión físicamente separados**: `poolMaster` (escrituras) y `poolReplica` (lecturas). |
| Interfaz de consumo | HTML+JS simple o React mínimo | Solo para demostrar el consumo de la API segura de Atlas. **No es lo evaluado.** |

> ⚠️ **Decisión crítica sobre XML.** PostgreSQL **NO** implementa `XMLVALIDATE` ni `CREATE XML SCHEMA COLLECTION`. Solo valida *well-formedness*. Si insertan XML en una columna `xml` sin más, **pierden el 100% del apartado XML** según la cláusula anti-plagio.
> - **Opción A (recomendada):** PostgreSQL + `plpython3u` + `lxml` → XSD guardado en tabla, función `validar_contra_xsd()` en el motor, trigger `BEFORE INSERT OR UPDATE`. Todo queda en el mismo cluster que se replica.
> - **Opción B (respaldo):** un contenedor extra de **SQL Server 2022 Express** solo para la capa XML, usando `CREATE XML SCHEMA COLLECTION` / `ALTER` / `DROP` nativos y columna `xml(CONTENT esquema)`. Es el soporte nativo más "de libro", pero fragmenta el stack.
> - Intenten A primero. Si `plpython3u` no se puede instalar en la imagen, salten a B sin rehacer nada más (está prevista dentro de la Fase 3).

### 0.2 Topología de contenedores

```
                        ┌────────────────────┐
   escrituras ────────► │  pg-master  :5432  │ ──WAL streaming──┐
                        │  MOR + XML + FDW   │                  │
                        │  (coordinador)     │                  ▼
                        └─────────┬──────────┘        ┌────────────────────┐
                                  │ postgres_fdw      │ pg-replica  :5433  │ ◄──── lecturas
                    ┌─────────────┴─────────────┐     │  HOT STANDBY (RO)  │
                    ▼                           ▼     └────────────────────┘
        ┌────────────────────┐      ┌────────────────────┐
        │ pg-norte    :5434  │      │ pg-sur      :5435  │
        │ frag. horizontal N │      │ frag. horizontal S │
        │ + frag. vertical   │      │ + frag. vertical   │
        └────────────────────┘      └────────────────────┘

        ┌────────────────────┐      ┌──────────────────────────┐
        │ api  :3000         │ ───► │ MongoDB Atlas (nube real) │
        │ poolMaster (W)     │      │ pacientes/sesiones/logs   │
        │ poolReplica (R)    │      └──────────────────────────┘
        │ mongoClient (Atlas)│
        └────────────────────┘
```

### 0.3 Estructura del repositorio

```
globalhealth/
├── docker-compose.yml
├── .env.example                  # NUNCA subir .env real con la URI de Atlas
├── docker/
│   ├── postgres/Dockerfile       # postgres:16 + plpython3 + python3-lxml
│   ├── master/postgresql.conf, pg_hba.conf, init-master.sh
│   ├── replica/init-replica.sh
│   └── shards/init-norte.sh, init-sur.sh
├── sql/
│   ├── 01_mor_types.sql          # tipos compuestos, métodos, herencia
│   ├── 02_mor_tables.sql         # tablas tipadas, nested tables, FK
│   ├── 03_mor_crud.sql           # demos CRUD completas
│   ├── 04_xml_registry.sql       # catálogo XSD + funciones de validación
│   ├── 05_xml_tables.sql         # columna xml + trigger de validación estricta
│   ├── 06_xml_crud.sql           # xpath, xmltable, update de nodos internos
│   ├── 07_frag_horizontal.sql    # fdw + particiones foráneas
│   ├── 08_frag_vertical.sql      # split público/financiero con misma PK
│   └── 99_seed.sql
├── xsd/expediente_clinico_v1.xsd  y  _v2.xsd   (para demostrar ALTER/actualización)
├── xml/samples/valido_*.xml, invalido_*.xml
├── mongo/
│   ├── 01_schema_validators.js   # $jsonSchema en Atlas
│   ├── 02_seed.js
│   └── 03_queries_agregacion.js  # $lookup, $match, $group, $limit
├── api/
│   ├── src/db/pgMaster.js, pgReplica.js, mongo.js
│   ├── src/routes/*.js
│   └── src/server.js
├── web/                          # interfaz mínima de consumo
├── docs/
│   ├── 01_arquitectura.md + diagramas
│   ├── 02_fragmentacion.md
│   ├── 03_costo_beneficio.md     # ← se exporta a PDF (la rúbrica lo exige)
│   └── 04_guion_defensa.md
└── scripts/
    ├── demo_replicacion.sh       # el "chaos engineering" en vivo
    ├── verify_all.sh             # smoke test de toda la arquitectura
    └── seed_all.sh
```

---

## 1. Trampas conocidas (léelas ANTES de arrancar Claude Code)

Estas son las cosas que hacen fracasar este proyecto. Ponlas en el `CLAUDE.md` del repo:

1. **`CREATE TABLE ... OF tipo` e `INHERITS` son incompatibles en PostgreSQL.** No intentes hacer una tabla tipada que además herede. Solución: usa **tablas tipadas** para `clinica` y `equipo_medico`, y **herencia (`INHERITS`)** para la jerarquía `persona → medico / enfermero / tecnico`. Así demuestras ambos requisitos sin colisión.
2. **Los "métodos del tipo"** en PostgreSQL se hacen con `CREATE FUNCTION nombre(t mi_tipo)` y se invocan como `SELECT (x).nombre` o `SELECT nombre(x)`. Prepara la explicación: es *notación funcional* equivalente a un método.
3. **`plpython3u` NO viene en la imagen oficial `postgres:16`.** Hay que construir imagen propia con `postgresql-plpython3-16` y `python3-lxml`. Si no, la Fase 3 muere.
4. **La réplica debe crearse con `pg_basebackup -R` y un `replication slot`**, no copiando el volumen a mano. Si el `PGDATA` de la réplica no está vacío, `pg_basebackup` falla.
5. **El esclavo es read-only por el motor**, no por la app. Demuéstralo intentando un `INSERT` en la réplica: debe dar `cannot execute INSERT in a read-only transaction`. Ese error es evidencia a favor tuyo.
6. **Separación física de conexiones:** el backend debe tener **dos objetos Pool distintos con host/puerto distintos**. Nada de un solo pool con un `if`. El profesor va a pedir ver el código.
7. **No pongas la URI de Atlas en el repo.** Usa `.env` + `.env.example`. Y en Atlas: usuario con rol mínimo, IP Access List configurada, TLS obligatorio.
8. **Particiones foráneas:** para que el `INSERT` se enrute a `pg-norte`/`pg-sur` necesitas PostgreSQL ≥ 11 y `postgres_fdw` con la opción `updatable`. Verifica el enrutamiento con `EXPLAIN`.
9. **Fragmentación vertical:** ambas tablas deben compartir **exactamente la misma PK** (`id_paciente`). La reconstrucción es un `JOIN` por esa llave — tienes que poder mostrar la consulta que reconstruye la relación completa.
10. **Ensaya el apagado del master varias veces.** El escenario de la rúbrica es: `docker stop pg-master` → las lecturas del dashboard siguen respondiendo → las escrituras fallan con un error controlado (no un crash del backend).

---

# FASES DE EJECUCIÓN

Cada fase trae: **objetivo → entregables → prompt listo para Claude Code → criterios de aceptación** (lo que tienes que verificar tú mismo antes de pasar a la siguiente).

---

## FASE 0 — Andamiaje del proyecto
**Rúbrica: base para todo**

### Entregables
- Repo con la estructura de la sección 0.3
- `CLAUDE.md` con el contexto del proyecto y las 10 trampas de la sección 1
- `.env.example`, `.gitignore`, `README.md`
- `docker-compose.yml` esqueleto con red `globalhealth-net` y volúmenes nombrados

### Prompt para Claude Code
```
Contexto: proyecto universitario de Bases de Datos Avanzadas. Debo construir
"GlobalHealth Unified System": arquitectura híbrida MOR + XML/XSD + MongoDB,
con replicación maestro/esclavo en Docker, fragmentación horizontal y vertical,
y despliegue de MongoDB en Atlas.

Tarea de esta fase (solo esta, no adelantes):
1. Crea la estructura de carpetas exacta que te paso abajo, con archivos vacíos
   o con placeholders comentados.
2. Crea un CLAUDE.md con: descripción del caso de negocio, stack elegido, la
   topología de contenedores y una sección "RESTRICCIONES DURAS" con estas reglas:
   - Nunca usar un solo pool de conexión para lecturas y escrituras.
   - Nunca insertar XML sin validación contra el XSD registrado en la BD.
   - CREATE TABLE ... OF e INHERITS son incompatibles en PostgreSQL.
   - Nunca commitear credenciales de MongoDB Atlas.
3. Crea docker-compose.yml con la red 'globalhealth-net', los volúmenes nombrados
   pgmaster_data, pgreplica_data, pgnorte_data, pgsur_data, y los servicios
   declarados pero comentados (los iremos activando por fases).
4. .env.example con todas las variables que vamos a necesitar.
5. .gitignore que excluya .env, node_modules, y volúmenes locales.

[pega aquí la estructura de carpetas de la sección 0.3]
```

### Criterios de aceptación
- [ ] `docker compose config` no da error
- [ ] `.env` está en `.gitignore`
- [ ] `CLAUDE.md` existe y contiene las restricciones duras

---

## FASE 1 — Replicación Maestro/Esclavo en Docker
**Rúbrica: 7.5% (Infraestructura Distribución) · Es la fase de mayor retorno**

### Entregables
- `docker/postgres/Dockerfile`: `postgres:16` + `postgresql-plpython3-16` + `python3-lxml`
- `pg-master` con `wal_level=replica`, `max_wal_senders`, slot de replicación, usuario `replicador`
- `pg-replica` inicializado con `pg_basebackup -R`, en hot standby
- `scripts/demo_replicacion.sh`: el guion del "chaos engineering"

### Prompt para Claude Code
```
Fase 1: replicación física maestro/esclavo de PostgreSQL 16 en dos contenedores
Docker aislados.

Requisitos obligatorios:
1. docker/postgres/Dockerfile basado en postgres:16 que instale
   postgresql-plpython3-16 y python3-lxml (los necesitaré después para validar XSD).
   Ambos contenedores usan esta misma imagen.
2. Servicio pg-master (puerto host 5432):
   - postgresql.conf: wal_level=replica, max_wal_senders=10, max_replication_slots=10,
     wal_keep_size=512MB, hot_standby=on, listen_addresses='*'
   - pg_hba.conf: entrada 'host replication replicador 0.0.0.0/0 scram-sha-256'
   - init script que cree el rol 'replicador' con REPLICATION LOGIN y el
     replication slot 'slot_replica_1'.
3. Servicio pg-replica (puerto host 5433):
   - entrypoint propio que, si PGDATA está vacío, ejecute
     pg_basebackup -h pg-master -U replicador -D $PGDATA -Fp -Xs -P -R
     --slot=slot_replica_1, y luego arranque en modo standby.
   - Debe esperar a que el master esté healthy (healthcheck con pg_isready +
     depends_on: condition: service_healthy).
4. scripts/verify_replication.sh que compruebe:
   - En master: SELECT client_addr, state, sync_state FROM pg_stat_replication;
   - En réplica: SELECT pg_is_in_recovery();  -> debe devolver t
   - Escribe una fila en master, espera 1s, la lee en la réplica.
   - Intenta un INSERT en la réplica y captura el error esperado
     'cannot execute INSERT in a read-only transaction'.
5. scripts/demo_replicacion.sh: guion para la defensa en vivo que ejecute paso a
   paso, con pausas y mensajes en pantalla: estado inicial -> escritura en master
   -> lectura en réplica -> docker stop pg-master -> lectura en réplica sigue
   funcionando -> intento de escritura devuelve error controlado -> docker start
   pg-master -> la replicación se recupera sola.

No uses imágenes de terceros tipo bitnami: la configuración debe ser explícita
y defendible línea por línea.
```

### Criterios de aceptación
- [ ] `pg_stat_replication` muestra la réplica en estado `streaming`
- [ ] `SELECT pg_is_in_recovery()` en réplica devuelve `t`
- [ ] Un `INSERT` en master aparece en la réplica en < 2 s
- [ ] Un `INSERT` en réplica falla con el error de read-only
- [ ] Con `docker stop pg-master`, la réplica sigue respondiendo `SELECT`
- [ ] Al reiniciar el master, la replicación se restablece sin intervención manual

---

## FASE 2 — Capa MOR (Objeto-Relacional)
**Rúbrica: parte del 8.5%**

### Modelo de datos objetivo
- **Tipos compuestos:** `tipo_direccion`, `tipo_contacto`, `tipo_credencial`, `tipo_equipo`
- **Herencia:** `persona` → `medico`, `enfermero`, `tecnico_laboratorio` (vía `INHERITS`)
- **Tabla tipada:** `clinica` con `CREATE TABLE clinica OF tipo_clinica`
- **Nested tables / colecciones vectorizadas:** `telefonos text[]`, `especialidades tipo_especialidad[]`
- **Composición:** `clinica` contiene `tipo_direccion` (dependiente, muere con la clínica)
- **Agregación:** `clinica` agrega `equipo_medico[]` (los equipos existen independientemente)
- **Métodos del tipo:** `antiguedad(persona)`, `nombre_completo(persona)`, `capacidad_total(tipo_clinica)`

### Prompt para Claude Code
```
Fase 2: capa Objeto-Relacional en pg-master. Genera sql/01_mor_types.sql,
sql/02_mor_tables.sql y sql/03_mor_crud.sql.

REGLA DURA: en PostgreSQL, CREATE TABLE ... OF <tipo> NO admite INHERITS.
Por eso separa la demostración así: tablas tipadas para clinica y equipo_medico;
herencia con INHERITS para la jerarquía de personal.

01_mor_types.sql debe incluir:
- Tipos compuestos: tipo_direccion(calle, ciudad, pais, codigo_postal),
  tipo_contacto(email, telefonos text[]), tipo_especialidad(codigo, nombre,
  anios_experiencia), tipo_credencial(numero_colegiado, fecha_emision, vigente),
  tipo_equipo(serie, modelo, fecha_calibracion).
- tipo_clinica: id, nombre, direccion tipo_direccion (COMPOSICIÓN, atributo
  complejo anidado), contacto tipo_contacto, region text.
- DOMAINs con CHECK para reforzar reglas (ej. email, codigo_pais CR/GT/HN).
- Funciones "método" invocables con notación funcional:
    nombre_completo(persona), antiguedad_anios(persona),
    resumen_direccion(tipo_direccion), especialidad_principal(medico).
  Añade comentarios COMMENT ON FUNCTION explicando que son los métodos del tipo.

02_mor_tables.sql debe incluir:
- Tabla base 'persona' y las hijas medico, enfermero, tecnico_laboratorio con
  INHERITS(persona), cada una con atributos propios (medico: especialidades
  tipo_especialidad[], credencial tipo_credencial; enfermero: turno, unidad;
  tecnico: area_lab, certificaciones text[]).
- Tabla tipada: CREATE TABLE clinica OF tipo_clinica (PRIMARY KEY(id));
- Tabla tipada: CREATE TABLE equipo_medico OF tipo_equipo (...) + tabla puente
  clinica_equipo para modelar la AGREGACIÓN (equipos que existen sin la clínica).
- Asignación de personal a clínicas con FK.
- Índices coherentes.

03_mor_crud.sql: demostración completa y comentada de CRUD sobre tablas tipadas
y jerarquía:
- INSERT usando constructores ROW() y literales de tipo compuesto y de arreglo.
- SELECT que: (a) accede a atributos anidados (clinica.direccion).ciudad,
  (b) desarma la nested table con unnest(), (c) invoca los métodos del tipo,
  (d) usa 'SELECT * FROM ONLY persona' vs 'SELECT * FROM persona' para
  demostrar el efecto de la herencia.
- UPDATE de un atributo interno de un tipo compuesto y de un elemento del arreglo
  (array_replace / subíndices).
- DELETE demostrando composición vs agregación.
Cada bloque con un comentario que diga qué requisito de la rúbrica cubre.
```

### Criterios de aceptación
- [ ] `\dT+` muestra los tipos compuestos; `\d clinica` muestra que es tabla tipada
- [ ] `SELECT * FROM persona` trae a médicos, enfermeros y técnicos; `ONLY persona` no
- [ ] `SELECT nombre_completo(m.*) FROM medico m` funciona (notación de método)
- [ ] Puedes actualizar un elemento de la nested table sin reescribir la fila entera
- [ ] Todo se replicó automáticamente a `pg-replica` (verifícalo, es un buen punto en la defensa)

---

## FASE 3 — Capa XML con XSD registrado y validación estricta
**Rúbrica: parte del 8.5% + zona de riesgo de la cláusula anti-plagio**

### Lo que exige el enunciado, punto por punto
1. Columnas tipo XML
2. **Declarar, registrar, actualizar y borrar** una plantilla XSD (= CRUD sobre el catálogo de esquemas)
3. **Forzar** validación estricta en la inserción
4. CRUD sobre porciones internas del XML (extracción de nodos y subconjuntos con funciones nativas)

### Entregables
- `xsd/expediente_clinico_v1.xsd` y `v2.xsd` (v2 añade un elemento → sirve para demostrar la *actualización* del esquema)
- Tabla catálogo `xsd_registry(nombre, version, contenido_xsd, activo, fecha_registro)`
- Funciones `registrar_xsd()`, `actualizar_xsd()`, `eliminar_xsd()`, `validar_xml_contra_xsd()`
- Tabla `expediente_clinico(id, id_paciente, esquema_ref, documento xml)` con **trigger `BEFORE INSERT OR UPDATE`** que rechaza documentos inválidos
- Archivos XML válidos e inválidos para demostrar en vivo

### Prompt para Claude Code
```
Fase 3: capa XML con validación XSD REAL dentro del motor de PostgreSQL.

CONTEXTO CRÍTICO: PostgreSQL no implementa XMLVALIDATE ni XML SCHEMA COLLECTION.
Solo valida well-formedness. El enunciado sanciona con pérdida total del apartado
insertar XML sin vincularlo al XSD registrado en la base de datos. Por eso la
validación se implementa como función del servidor en PL/Python3u con lxml
(la imagen Docker de la Fase 1 ya trae postgresql-plpython3-16 y python3-lxml).

Genera:

1. xsd/expediente_clinico_v1.xsd — esquema de expediente clínico regulado con:
   raíz <expediente>, elementos obligatorios <paciente> (id, nombre, fechaNacimiento
   tipo xs:date), <diagnosticos> con 1..N <diagnostico> (código CIE-10 restringido
   por xs:pattern, descripcion, fecha, medicoResponsable), <tratamientos>,
   <firmaDigital>. Usa xs:sequence, minOccurs/maxOccurs, xs:simpleType con
   restricciones y un atributo obligatorio 'version'. Debe ser lo bastante estricto
   como para que sea fácil demostrar rechazos.
2. xsd/expediente_clinico_v2.xsd — igual pero añadiendo <alergias> obligatorio
   (sirve para demostrar la ACTUALIZACIÓN de la plantilla registrada).
3. sql/04_xml_registry.sql:
   - CREATE EXTENSION plpython3u;
   - Tabla xsd_registry(id, nombre, version, contenido_xsd xml NOT NULL, activo
     boolean, fecha_registro timestamptz, UNIQUE(nombre,version)).
   - Función PL/Python validar_xml_contra_xsd(p_xml text, p_xsd text)
     RETURNS boolean, que use lxml.etree.XMLSchema y levante
     plpy.error() con el mensaje exacto del validador cuando falle
     (el mensaje de error es la evidencia en la defensa).
   - Procedimientos: registrar_xsd(nombre, version, contenido),
     actualizar_xsd(nombre, version_nueva, contenido) que desactiva la anterior,
     eliminar_xsd(nombre, version) con protección si hay documentos que lo usan.
4. sql/05_xml_tables.sql:
   - Tabla expediente_clinico(id serial PK, id_paciente int, xsd_nombre text,
     xsd_version text, documento xml NOT NULL, creado_en timestamptz,
     FK compuesta a xsd_registry).
   - Trigger BEFORE INSERT OR UPDATE que busca el XSD activo referenciado y llama
     a validar_xml_contra_xsd. Si no hay XSD registrado para esa referencia,
     también debe abortar (nunca permitir inserción sin esquema).
5. sql/06_xml_crud.sql — CRUD sobre porciones internas del documento:
   - READ: xpath() para extraer nodos individuales; xmltable() para proyectar
     los <diagnostico> como conjunto relacional; xpath_exists() como predicado
     en WHERE; consultas con namespaces.
   - UPDATE de un nodo interno: implementa una función
     actualizar_nodo_xml(id, xpath, valor_nuevo) usando xslt_process (extensión xml2)
     o reconstrucción con XMLELEMENT/XMLAGG. Explica en comentarios por qué
     PostgreSQL no tiene XML DML tipo 'modify()' y cómo se resuelve.
   - DELETE de un subnodo (ej. quitar un <diagnostico> por código).
   - Cada operación debe volver a pasar por el trigger de validación: demuéstralo.
6. xml/samples/: 3 documentos válidos y 4 inválidos (falta elemento obligatorio,
   patrón CIE-10 incorrecto, orden de secuencia roto, atributo version ausente),
   más un script SQL que intente insertarlos todos y muestre los errores.

PLAN B: si plpython3u no se puede instalar, dímelo de inmediato y en lugar de
seguir, genera la variante con un contenedor SQL Server 2022 Express usando
CREATE XML SCHEMA COLLECTION / ALTER / DROP y columnas xml(CONTENT coleccion).
```

### Criterios de aceptación
- [ ] Insertar un XML válido → OK
- [ ] Insertar cada uno de los 4 XML inválidos → error con mensaje del validador XSD
- [ ] `registrar_xsd` → `actualizar_xsd` a v2 → un documento que era válido en v1 ahora se rechaza
- [ ] `eliminar_xsd` protege si hay documentos dependientes
- [ ] `xmltable()` devuelve los diagnósticos como filas relacionales
- [ ] Modificar un nodo interno funciona y vuelve a validar

---

## FASE 4 — MongoDB Atlas: telemetría y jerarquía documental
**Rúbrica: parte del 8.5% + parte del 5% (Nube)**

### Modelo Abuelo → Padre → Hijo
```
pacientes (abuelo)     _id, documento, nombre, region, clinica_id
   └─ sesiones (padre)  _id, paciente_id (ref), tipo: "telemedicina"|"monitoreo",
                        inicio, fin, medico_id
        └─ sensor_logs (hijo) _id, sesion_id (ref), timestamp, tipo_sensor,
                        valor, unidad, alerta:boolean
```
Justificación defendible: **referencias** en lugar de embebido porque los `sensor_logs` crecen sin límite (riesgo del tope de 16 MB por documento) y se ingestan a alta frecuencia. Los datos de baja cardinalidad y lectura conjunta (ej. `signos_vitales_resumen`) sí van embebidos → demuestras que dominas ambos criterios.

### Prompt para Claude Code
```
Fase 4: capa NoSQL en MongoDB Atlas.

1. mongo/01_schema_validators.js: crea las colecciones pacientes, sesiones y
   sensor_logs con $jsonSchema validator (bsonType, required, enum para
   tipo_sensor y region) y validationLevel: "strict". Índices: sensor_logs sobre
   {sesion_id:1, timestamp:-1}, sesiones sobre {paciente_id:1, inicio:-1},
   pacientes sobre {documento:1} unique. Documenta por qué cada índice.
2. mongo/02_seed.js: genera datos realistas — 30 pacientes de 3 regiones,
   4-6 sesiones por paciente, 200-500 sensor_logs por sesión, con algunos
   valores fuera de rango marcados como alerta:true. Usa ObjectId reales para
   las referencias.
3. mongo/03_queries_agregacion.js — cada consulta con comentario del operador
   que demuestra:
   a) Operadores de comparación y lógicos: $gt, $lt, $in, $and, $or, $ne.
   b) $limit + $skip + $sort (paginación de logs).
   c) $lookup de sensor_logs -> sesiones -> pacientes (JOIN NoSQL en dos saltos,
      usando $lookup con pipeline anidado). Debe reconstruir la jerarquía completa
      abuelo-padre-hijo en un solo resultado.
   d) Agregación analítica: promedio, máximo y desviación de cada tipo_sensor
      por paciente y por región ($group, $avg, $stdDevPop, $bucket).
   e) $unwind + $project + $addFields.
   f) Una pipeline que detecte sesiones con más de N alertas ($match tras $group).
   g) UPDATE complejo: $set con arrayFilters, $push a un arreglo embebido,
      updateMany con operador condicional.
   h) $out o $merge a una colección de resumen (demuestra materialización).
4. Añade un comentario al inicio de cada archivo explicando el criterio
   referencia-vs-embebido para la defensa.
5. mongo/README.md con los pasos exactos de aprovisionamiento en Atlas:
   creación del cluster, database user con rol mínimo (readWrite solo en la BD),
   IP Access List, obtención de la connection string SRV, y verificación de TLS.
   NUNCA escribas credenciales reales en el repo: solo variables de entorno.
```

### Criterios de aceptación
- [ ] El cluster existe en Atlas y responde desde fuera del contenedor
- [ ] Insertar un documento que viola el `$jsonSchema` es rechazado
- [ ] El `$lookup` de dos saltos devuelve paciente + sesión + logs anidados
- [ ] La agregación por región devuelve estadísticas coherentes
- [ ] Las credenciales solo viven en `.env`

---

## FASE 5 — Fragmentación horizontal y vertical
**Rúbrica: parte del 5%**

### Diseño
**Horizontal:** `paciente_global` particionada por `region` (`LIST`), con la partición `NORTE` viviendo como *foreign table* en `pg-norte` y `SUR` en `pg-sur`. El coordinador (`pg-master`) ve una tabla única.

**Vertical:** en cada nodo, `paciente_publico(id_paciente PK, nombre, telefono, email, direccion)` y `paciente_financiero(id_paciente PK, num_seguro, plan, saldo, tarjeta_hash)` — **misma PK**, reconstrucción por `JOIN`. Justificación: los datos financieros tienen distinto perfil de acceso y distinto régimen de confidencialidad, y se les puede aplicar cifrado y permisos separados (`REVOKE` al rol del dashboard).

### Prompt para Claude Code
```
Fase 5: fragmentación distribuida.

1. Añade a docker-compose los servicios pg-norte (5434) y pg-sur (5435) con la
   misma imagen custom.
2. sql/07_frag_horizontal.sql (se ejecuta en pg-master como coordinador):
   - CREATE EXTENSION postgres_fdw;
   - CREATE SERVER nodo_norte / nodo_sur + USER MAPPING.
   - En cada nodo remoto: tabla física pacientes_norte / pacientes_sur.
   - En el coordinador: CREATE TABLE paciente_global (...) PARTITION BY LIST (region);
     luego CREATE FOREIGN TABLE para cada nodo y ATTACH PARTITION.
   - Consultas de demostración: INSERT que se enruta al nodo correcto,
     SELECT global que hace fan-out, EXPLAIN (VERBOSE, COSTS OFF) que muestre
     el partition pruning y el Foreign Scan.
   - Una consulta que toque un solo nodo y otra que toque ambos, con comentario
     comparando el costo.
3. sql/08_frag_vertical.sql:
   - En cada nodo: paciente_publico y paciente_financiero con la MISMA llave
     primaria id_paciente (regla de reconstrucción).
   - Vista paciente_completo que reconstruye con JOIN por id_paciente.
   - Rol 'dashboard_ro' con SELECT solo sobre paciente_publico; demuestra con
     SET ROLE que no puede leer paciente_financiero.
   - Consulta que demuestre que la reconstrucción es lossless: comparar
     COUNT(*) de la vista contra COUNT(*) de cada fragmento.
4. scripts/verify_fragmentacion.sh que ejecute todo lo anterior y muestre
   evidencia en consola.
5. docs/02_fragmentacion.md con dos diagramas en Mermaid: uno de la
   fragmentación horizontal por región y otro de la vertical con la PK
   compartida. Incluye las reglas de corrección (completitud, reconstrucción,
   disyunción) y verifica que el diseño las cumple.
```

### Criterios de aceptación
- [ ] `INSERT` con `region='NORTE'` aparece físicamente en `pg-norte`, no en `pg-sur`
- [ ] `SELECT ... WHERE region='SUR'` muestra *partition pruning* en el `EXPLAIN`
- [ ] La vista `paciente_completo` reconstruye todas las filas sin pérdida ni duplicación
- [ ] El rol `dashboard_ro` recibe *permission denied* sobre `paciente_financiero`
- [ ] Los diagramas están hechos (la rúbrica pide explícitamente "diagramación")

---

## FASE 6 — Backend con separación física de conexiones
**Rúbrica: exigido por la cláusula anti-plagio + habilita la demo del 7.5%**

### Prompt para Claude Code
```
Fase 6: API Node.js + Express en un contenedor.

REGLA DURA E INNEGOCIABLE: dos clientes de base de datos físicamente separados.
- src/db/pgMaster.js  -> Pool apuntando a pg-master:5432. SOLO escrituras.
- src/db/pgReplica.js -> Pool apuntando a pg-replica:5432. SOLO lecturas.
No los unifiques, no crees un wrapper que decida con un if, no compartas
configuración. Cada archivo lleva un comentario de cabecera explicando su rol.
Añade una salvaguarda: en pgReplica.js, un helper query() que lance un error si
la sentencia empieza por INSERT/UPDATE/DELETE (defensa en profundidad).

Endpoints mínimos:
- POST /api/personal            -> escribe en master (MOR, tabla tipada/herencia)
- GET  /api/personal            -> lee de réplica
- GET  /api/dashboard/resumen   -> consulta pesada agregada, SIEMPRE de la réplica
- POST /api/expedientes         -> inserta XML, dispara validación XSD; si falla,
                                   devuelve 422 con el mensaje del validador
- GET  /api/expedientes/:id/diagnosticos -> xmltable() sobre la réplica
- GET  /api/pacientes?region=   -> consulta a la tabla fragmentada
- GET  /api/telemetria/:pacienteId -> $lookup contra MongoDB Atlas
- GET  /api/telemetria/alertas  -> pipeline de agregación de Atlas
- GET  /health                  -> reporta el estado INDIVIDUAL de master, réplica
                                   y Atlas (up/down por separado)

Manejo de fallos (esto se demuestra en la defensa):
- Si pg-master está caído, los endpoints de escritura devuelven 503 con un
  mensaje claro ("Master no disponible: escrituras suspendidas") y los de
  lectura siguen respondiendo 200 desde la réplica. El proceso NO debe caerse.
- Timeouts cortos en el pool del master (connectionTimeoutMillis: 2000) para que
  la demo no se quede colgada 30 segundos frente al profesor.
- Logging que imprima en cada request a qué nodo fue (MASTER/REPLICA/ATLAS).
  Ese log es la evidencia visual de la separación durante la defensa.

Credenciales solo por variables de entorno. Dockeriza la API y agrégala al compose.
```

### Criterios de aceptación
- [ ] `grep -r "Pool" api/src/db/` muestra dos pools con hosts distintos
- [ ] Con el master apagado: `GET /api/dashboard/resumen` → 200; `POST /api/personal` → 503
- [ ] `/health` reporta los tres backends por separado
- [ ] El log de cada request indica el nodo destino

---

## FASE 7 — Interfaz de consumo
**Rúbrica: "consumo a través de API segura" dentro del 5% · NO SOBREINVERTIR AQUÍ**

El enunciado dice explícitamente que **no se aceptarán explicaciones meramente visuales**. La interfaz solo debe probar que el cluster en la nube se consume por una API segura.

### Prompt para Claude Code
```
Fase 7: interfaz mínima de consumo (una sola página, sin framework pesado).

Secciones:
1. Panel de estado: consulta /health cada 3 s y muestra tres semáforos —
   MASTER, RÉPLICA, ATLAS. Cuando apague el master en vivo, el semáforo debe
   ponerse rojo mientras los otros dos siguen verdes. Este panel es el punto
   central de la demostración.
2. Formulario de alta de personal (escritura -> master) que muestre el error
   503 de forma legible cuando el master esté caído.
3. Tabla del dashboard (lectura -> réplica) con un badge que diga
   "Servido por: RÉPLICA".
4. Formulario de carga de expediente XML: pegar XML, enviar, y mostrar el
   mensaje de validación XSD tal cual lo devuelve el motor (éxito o rechazo).
5. Visor de telemetría desde Atlas con un gráfico simple de la serie de sensores
   y la lista de alertas.

Diseño sobrio, legible en proyector: fuente grande, alto contraste, sin
animaciones. Es una herramienta de demostración técnica, no un producto.
```

### Criterios de aceptación
- [ ] El panel de estado refleja en < 5 s la caída del master
- [ ] Cada vista indica de qué nodo vienen los datos
- [ ] El error de validación XSD se ve textualmente en pantalla

---

## FASE 8 — Documentación, diagramas y evaluación costo/beneficio
**Rúbrica: el PDF de costo/beneficio es exigido explícitamente dentro del 5%**

### Entregables
1. `docs/01_arquitectura.md` — diagrama general, decisiones y justificaciones
2. `docs/02_fragmentacion.md` — diagramas horizontal y vertical (ya de la Fase 5)
3. **`docs/03_costo_beneficio.pdf`** — evaluación **cuantitativa**
4. `docs/04_guion_defensa.md` — guion minutado de 15 minutos

### Estructura del análisis costo/beneficio (el profesor pide números, no adjetivos)

| Concepto | Self-hosted (VM propia) | MongoDB Atlas | Fuente |
|---|---|---|---|
| Cómputo/instancia mensual | VM 2 vCPU / 4 GB × 3 nodos | Tier del cluster (M0/M10/M20) | verificar precios vigentes |
| Almacenamiento | GB/mes + IOPS | Incluido / por GB | " |
| Transferencia de salida | GB/mes | GB/mes | " |
| Backups | Costo de snapshots + retención | Backups continuos según tier | " |
| **Horas de operación** | h/mes × costo hora DBA | ≈ 0 (gestionado) | estimación propia justificada |
| Costo de una hora de caída | usuarios × ingreso/hora | idem, pero con SLA | estimación |
| **TCO 12 meses** | Σ | Σ | calculado |

Añadan: cálculo del **punto de equilibrio** (a partir de cuántos GB/nodos deja de convenir Atlas), análisis de **latencia** por región centroamericana (Atlas tiene regiones más cercanas que un datacenter propio), y **riesgos**: vendor lock-in, soberanía de datos médicos y cumplimiento normativo.

> ⚠️ **Verifiquen los precios en las páginas oficiales de MongoDB Atlas y del proveedor de VM antes de entregar.** Poner cifras inventadas en un análisis "cuantitativo" es el tipo de cosa que el profesor pincha en la defensa.

### Prompt para Claude Code
```
Fase 8: documentación.

1. docs/01_arquitectura.md: diagrama Mermaid de la topología completa,
   tabla de decisiones (decisión / alternativas descartadas / justificación),
   y una sección "Trazabilidad con la rúbrica" que mapee cada rubro con los
   archivos y comandos que lo demuestran.
2. docs/03_costo_beneficio.md: la plantilla cuantitativa que te paso abajo,
   con las fórmulas ya montadas y celdas [VERIFICAR] donde yo debo pegar los
   precios reales. Incluye cálculo de TCO a 12 meses, punto de equilibrio y
   una tabla de riesgos con probabilidad e impacto. Genera también el script
   para exportarlo a PDF.
   [pega aquí la tabla de arriba]
3. docs/04_guion_defensa.md: guion minutado de 15 minutos para dos personas:
   - 0:00-1:30 Caso de negocio y visión de arquitectura (persona A)
   - 1:30-4:30 MOR en vivo: tipos, herencia, tabla tipada, método, CRUD (A)
   - 4:30-7:00 XML: registrar XSD, insertar válido, insertar inválido y mostrar
     el rechazo, xmltable (B)
   - 7:00-9:00 MongoDB Atlas: jerarquía y $lookup en vivo (B)
   - 9:00-11:30 CHAOS: docker stop pg-master, lecturas siguen, escrituras 503,
     restauración (A)
   - 11:30-13:00 Fragmentación: EXPLAIN con partition pruning + reconstrucción
     vertical (B)
   - 13:00-15:00 Costo/beneficio y cierre (ambos)
   Incluye los comandos exactos a ejecutar en cada bloque, en orden, copiables.
4. scripts/verify_all.sh: smoke test que valide de una vez todos los criterios
   de aceptación de las fases 1 a 6 e imprima un checklist con ✓/✗.
```

---

## FASE 9 — Ensayo, contingencia y defensa
**Rúbrica: 4% (Defensa Oral e Integración) · NO LA SALTEN**

### Preparación material
- [ ] `docker compose down -v && docker compose up -d` desde cero, verificando que todo levanta solo
- [ ] Datos semilla cargados y **respaldo** de los volúmenes por si algo se corrompe
- [ ] Terminal con fuente grande y 3 paneles: master, réplica, logs de la API
- [ ] Capturas de pantalla de cada demo funcionando, **por si falla el equipo en el aula**
- [ ] Portátil con todo local: no dependan del wifi del aula salvo para Atlas (y tengan respaldo con MongoDB local + capturas de Atlas)

### Reparto de la pareja
Ambos deben poder responder **cualquier** pregunta. El profesor suele preguntarle al que no expuso ese bloque. Estudien los dos, expongan repartido.

### Banco de preguntas de la defensa (la rúbrica nombra CAP, BASE y consistencia)

**Teorema CAP**
- ¿Qué garantiza tu sistema PostgreSQL maestro/esclavo bajo partición de red? → Con replicación asíncrona: **AP** con consistencia eventual en el esclavo; si configuras `synchronous_commit=remote_apply` te mueves hacia **CP** sacrificando disponibilidad de escritura.
- ¿Y MongoDB Atlas? → Un replica set con `writeConcern: majority` y `readConcern: majority` es **CP**; con lecturas desde secundarios y `w:1` se comporta como **AP**.
- CAP habla de comportamiento **durante una partición**, no en operación normal. Menciona PACELC (*else Latency vs Consistency*) — suma muchos puntos.

**Modelo BASE vs ACID**
- ACID en la capa MOR/XML (transacciones del personal médico y expedientes: no puedes perder un diagnóstico).
- BASE en la capa de telemetría (millones de logs de sensores: *Basically Available, Soft state, Eventually consistent*). **Justifica por qué cada dominio del caso usa un modelo distinto** — esa es literalmente la tesis del proyecto.

**Consistencia**
- ¿Qué pasa si el dashboard lee de la réplica un dato recién escrito en el master? → *Replication lag*; muéstralo midiendo con `pg_last_xact_replay_timestamp()`. Explica *read-your-own-writes* y por qué las lecturas críticas posteriores a una escritura deben ir al master.
- ¿Cómo mides el lag? → `pg_stat_replication.replay_lag` en el master.

**Preguntas de infraestructura**
- ¿El esclavo puede escribir? ¿Por qué no? → Está en `recovery`; el motor lo impide.
- Si el master no vuelve, ¿cómo promuevo la réplica? → `pg_ctl promote` / `SELECT pg_promote()`. Ten el comando listo: si te lo piden en vivo y lo ejecutas, es nota extra.
- ¿Por qué replicación física y no lógica? → Copia byte a byte de todo el cluster, menor overhead, standby idéntico; la lógica sería para replicar tablas selectivas o entre versiones distintas.
- Reglas de corrección de la fragmentación: **completitud, reconstrucción, disyunción**. Demuestra que las cumples.
- ¿Por qué referencias y no embebido en Mongo? → Crecimiento ilimitado de `sensor_logs` y límite de 16 MB por documento.

### Prompt para Claude Code
```
Fase 9: preparación de la defensa.

1. Crea docs/05_banco_preguntas.md con 30 preguntas probables y respuestas
   técnicas de 3-5 líneas, agrupadas en: CAP/PACELC, BASE vs ACID, consistencia
   y replication lag, MOR, XML/XSD, MongoDB, fragmentación, cloud/costos.
2. Crea scripts/reset_demo.sh que devuelva todo el entorno a un estado limpio y
   sembrado con un solo comando (para reintentar la demo si algo falla).
3. Crea docs/06_plan_contingencia.md: qué hacer si falla el wifi, si Atlas no
   responde, si un contenedor no levanta, si el pg_basebackup falla. Cada
   escenario con su comando de recuperación y su alternativa de respaldo.
4. Ejecuta scripts/verify_all.sh y reporta cualquier criterio en ✗.
```

---

## 2. Checklist final contra la rúbrica

**Arquitectura Híbrida — 8.5%**
- [ ] Tipos compuestos con atributos complejos y funciones internas del tipo
- [ ] Herencia de tipos demostrada (`ONLY` vs sin `ONLY`)
- [ ] Tablas tipadas (`CREATE TABLE ... OF`)
- [ ] Nested tables / colecciones vectorizadas (teléfonos, especialidades)
- [ ] Composición **y** agregación diferenciadas y explicables
- [ ] CRUD completo sobre tablas tipadas
- [ ] Columna XML + XSD **registrado en la BD**
- [ ] XSD: declarar / registrar / actualizar / borrar (los 4 verbos)
- [ ] Validación estricta forzada, con rechazos demostrables
- [ ] CRUD sobre nodos internos (xpath, xmltable, update y delete de subnodos)
- [ ] MongoDB: jerarquía Paciente → Sesión → Logs
- [ ] Operadores de relación, límites y agregaciones
- [ ] `$lookup` entre colecciones

**Infraestructura Distribución — 7.5%**
- [ ] Master y esclavo en contenedores **aislados**
- [ ] Permisos y usuario de replicación configurados
- [ ] Réplica inicializada y validada (`pg_stat_replication`)
- [ ] Parada controlada del master en vivo
- [ ] El esclavo sigue sirviendo lecturas tras la caída
- [ ] Separación física de conexiones en el backend (dos pools)

**Fragmentación y Nube — 5%**
- [ ] Fragmentación horizontal por región en nodos separados
- [ ] Fragmentación vertical con PK idéntica y reconstrucción demostrada
- [ ] Diagramas de ambas fragmentaciones
- [ ] Cluster real aprovisionado en la nube
- [ ] Consumo mediante API segura (TLS, credenciales en entorno, IP allowlist)
- [ ] **PDF de costo/beneficio adjunto, con cifras verificadas**

**Defensa Oral — 4%**
- [ ] Dominio de CAP (y PACELC)
- [ ] Dominio de BASE vs ACID y por qué cada capa usa uno
- [ ] Consistencia y replication lag medidos, no solo mencionados
- [ ] Guion de 15 min ensayado por ambos
- [ ] Plan de contingencia listo

---

## 3. Nota importante

La defensa es oral, presencial y con preguntas cruzadas del profesor. Claude Code puede construir la infraestructura, pero **el 4% de la defensa y buena parte de los otros rubros dependen de que ustedes entiendan cada línea**. Recomendación concreta: al terminar cada fase, pídanle a Claude Code que les explique el "por qué" de las decisiones antes de pasar a la siguiente, y reserven un bloque completo para leer el código generado línea por línea. Si no pueden explicar por qué el esclavo rechaza escrituras o por qué el XSD se valida en el motor y no en la aplicación, el proyecto no se sostiene aunque funcione.
