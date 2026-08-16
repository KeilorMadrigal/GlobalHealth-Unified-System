# Banco de preguntas de la defensa

30 preguntas probables con respuestas técnicas de 3–5 líneas. Estudiar
ambos integrantes: el profesor suele preguntarle al que no expuso ese
bloque.

## CAP / PACELC

**1. ¿Qué garantiza tu réplica PostgreSQL bajo una partición de red?**
Con replicación asíncrona (nuestra configuración, `synchronous_commit`
por defecto): **AP** — el maestro sigue aceptando escrituras aunque la
réplica quede aislada, con consistencia eventual del lado del standby. Si
configuráramos `synchronous_commit=remote_apply` nos moveríamos hacia
**CP**, sacrificando disponibilidad de escritura si la réplica no
responde.

**2. ¿Y MongoDB Atlas?**
Un replica set con `writeConcern: majority` y `readConcern: majority` es
**CP**. Nuestro seed usa `w: "majority"` en la connection string
(`retryWrites=true&w=majority`), así que por defecto nos comportamos como
CP en escritura; si leyéramos de secundarios con `readPreference:
secondary` nos acercaríamos a AP.

**3. ¿CAP aplica todo el tiempo o solo en un escenario específico?**
Solo describe el comportamiento **durante una partición de red**. Fuera de
esa ventana, un sistema bien diseñado puede ser consistente y disponible
simultáneamente. Por eso PACELC es más útil: agrega que, incluso *sin*
partición (Else), hay que elegir entre Latencia y Consistencia.

**4. ¿Dónde se ve PACELC en este proyecto?**
En la réplica de lectura: en operación normal (sin partición), leer de
`pg-replica` da menor latencia que leer siempre de `pg-master`, a costa de
poder leer un dato con un pequeño *replication lag* (ver
`pg_last_xact_replay_timestamp()`). Elegimos **Latencia sobre
Consistencia estricta** para las lecturas del dashboard a propósito.

## BASE vs ACID

**5. ¿Dónde usan ACID y por qué?**
En la capa MOR/XML (`pg-master`): personal médico y expedientes clínicos.
Un diagnóstico no puede perderse ni quedar a medio insertar; cada
`INSERT`/`UPDATE` corre en una transacción que o se aplica completa o no
se aplica, reforzada además por el trigger de validación XSD que aborta la
transacción si el documento es inválido.

**6. ¿Dónde usan BASE y por qué?**
En `sensor_logs` de MongoDB: millones de lecturas de sensores a alta
frecuencia. *Basically Available* (Atlas sigue aceptando escrituras aunque
algún nodo esté ocupado), *Soft state* (el `signos_vitales_resumen`
embebido en `sesiones` es un promedio que se recalcula, no una verdad
absoluta), *Eventually consistent* (una lectura tardía de `sensor_logs`
no invalida el sistema).

**7. ¿Por qué no usar ACID también para la telemetría?**
El costo de coordinación transaccional estricta sobre miles de escrituras
por segundo de sensores sería prohibitivo, y no se necesita: perder o
tener un pequeño desfase en una lectura de frecuencia cardíaca no tiene el
mismo impacto que perder un diagnóstico firmado.

**8. Den un ejemplo concreto de la tesis "cada dominio usa el modelo que le corresponde".**
`expediente_clinico` (ACID, PostgreSQL, trigger de validación que aborta
la transacción) vs. `sensor_logs` (BASE, MongoDB, `insertMany` con
`ordered: false` para no bloquear todo el lote si un documento falla). Es
la misma arquitectura resolviendo dos problemas con distinto perfil de
riesgo.

## Consistencia y replication lag

**9. ¿Qué pasa si el dashboard lee de la réplica justo después de una escritura en el master?**
Puede ver el estado *anterior* a esa escritura durante el *replication
lag* (normalmente milisegundos en nuestro entorno local). Es
*read-your-own-writes* violado a propósito: por diseño, las lecturas
críticas inmediatamente posteriores a una escritura deberían ir al master,
no a la réplica.

**10. ¿Cómo miden el lag en este proyecto?**
`SELECT replay_lag FROM pg_stat_replication;` en el maestro, o
`SELECT now() - pg_last_xact_replay_timestamp();` en la réplica. En
`scripts/verify_replication.sh` lo comprobamos indirectamente: escribimos
en el master, esperamos 1s, y confirmamos que ya está en la réplica.

**11. ¿El esclavo puede escribir? ¿Por qué no?**
No: está permanentemente en modo `recovery` (`pg_is_in_recovery()` =
`t`), aplicando WAL que recibe del maestro. El motor rechaza cualquier
`INSERT`/`UPDATE`/`DELETE` con `cannot execute INSERT in a read-only
transaction` — lo comprobamos en vivo en la demo de caos.

**12. Si el master no vuelve, ¿cómo promueven la réplica?**
`docker exec pg-replica psql -U postgres -c "SELECT pg_promote();"` (o
`pg_ctl promote` desde shell). Esto saca a la réplica de modo standby y la
convierte en un maestro independiente, aceptando escrituras. Ensayarlo
antes de la defensa, no improvisarlo la primera vez en vivo.

## MOR (Objeto-Relacional)

**13. ¿Por qué `clinica` es tabla tipada y `medico` usa herencia, y no al revés?**
Porque `CREATE TABLE ... OF <tipo>` e `INHERITS` son incompatibles en
PostgreSQL — no se puede usar ambos en la misma tabla. Elegimos tabla
tipada donde queríamos un tipo compuesto reusable con atributos anidados
(`tipo_clinica`), y herencia donde queríamos una jerarquía real
persona→médico/enfermero/técnico con especialización de columnas.

**14. Demuestren la diferencia entre `SELECT * FROM persona` y `SELECT * FROM ONLY persona`.**
`ONLY persona` da 0 filas porque nunca insertamos directamente en la tabla
padre; todo el personal vive en `medico`/`enfermero`/`tecnico_laboratorio`.
`SELECT * FROM persona` (sin `ONLY`) hace `UNION ALL` automático con las
tres tablas hijas y devuelve el total. Verificado en
`sql/03_mor_crud.sql`.

**15. ¿Por qué `personal_clinica.persona_id` no es una FK real?**
Porque una FK `REFERENCES persona(id)` en PostgreSQL solo valida contra
las filas físicamente almacenadas en `persona`, **no** contra sus hijas
por `INHERITS`. Como el personal siempre vive en la tabla hija, una FK
literal rechazaría todos los inserts. Lo resolvimos con un trigger
(`trg_validar_persona_existe`) que consulta `persona` sin `ONLY`.

**16. ¿Cómo invocan un "método" de un tipo en PostgreSQL?**
No hay métodos de verdad; se simulan con funciones cuyo primer parámetro
es el tipo: `CREATE FUNCTION nombre_completo(p persona) ...`. Se invocan
como función normal (`SELECT nombre_completo(p.*)`) o, si el nombre de
función coincide con el patrón, con notación de punto (`(p).campo`).

**17. Den un ejemplo de composición y uno de agregación en su modelo.**
Composición: `clinica.direccion` (tipo `tipo_direccion` embebido) muere
con la fila de la clínica, no tiene tabla propia. Agregación:
`clinica_equipo` vincula `clinica` con `equipo_medico`, pero el equipo
tiene vida propia — `ON DELETE RESTRICT` del lado del equipo evita que se
borre por accidente al borrar una clínica.

## XML / XSD

**18. ¿Por qué no usaron el tipo `xml` nativo de PostgreSQL para validar contra el esquema?**
Porque PostgreSQL solo garantiza *well-formedness* con el tipo `xml`; no
implementa `XMLVALIDATE` ni `CREATE XML SCHEMA COLLECTION`. Insertar XML
sin más pierde el apartado completo según la cláusula anti-plagio.

**19. ¿Dónde vive la validación XSD real?**
En una función `LANGUAGE plpython3u` (`validar_xml_contra_xsd`) que usa
`lxml.etree.XMLSchema`, invocada por un trigger `BEFORE INSERT OR UPDATE`
en `expediente_clinico`. Si el XML no cumple el esquema, `plpy.error()`
levanta una excepción con el mensaje exacto del validador y aborta la
transacción.

**20. Demuestren los 4 verbos del CRUD sobre el catálogo XSD.**
`registrar_xsd` (INSERT en `xsd_registry`), `actualizar_xsd` (desactiva
la versión anterior e inserta la nueva como activa), `eliminar_xsd`
(bloqueado si hay `expediente_clinico` dependientes — lo demostramos con
`eliminar_xsd('expediente_clinico','v1')` fallando). El "declarar" es la
definición del propio archivo `.xsd`.

**21. No hay `modify()` de XQuery en PostgreSQL. ¿Cómo actualizan un nodo interno?**
Con una función PL/Python3u (`actualizar_nodo_xml`) que parsea el
documento con `lxml`, localiza el nodo por XPath, cambia su texto, y
reescribe el documento completo con un `UPDATE` real — eso hace que
vuelva a pasar por el trigger de validación (lo probamos borrando el
último diagnóstico de un expediente: el trigger lo rechaza porque el XSD
exige al menos uno).

## MongoDB

**22. ¿Por qué `sensor_logs` es una colección separada y no un arreglo embebido en `sesiones`?**
Porque crece sin límite (una sesión de monitoreo genera 200–500 lecturas,
y en producción real serían muchas más) y un documento de MongoDB tiene un
tope duro de 16 MB. Embeber también haría que cada lectura/escritura de
metadatos de la sesión cargara potencialmente miles de lecturas
innecesariamente.

**23. Den un ejemplo de algo que SÍ embebieron y por qué.**
`signos_vitales_resumen` y `notas` dentro de `sesiones`: son de baja
cardinalidad, se leen siempre junto con la sesión, y no crecen sin
control. Embeberlos evita un `$lookup` extra en la consulta más común del
dashboard.

**24. Muestren un `$lookup` de dos saltos reconstruyendo la jerarquía completa.**
`sensor_logs` → `$lookup` con pipeline anidado hacia `sesiones` → dentro
de ese pipeline, otro `$lookup` hacia `pacientes`. Ver
`mongo/03_queries_agregacion.js`, bloque (c): reconstruye paciente + sesión
+ log en un solo documento de salida.

**25. ¿Cómo se refuerza el esquema en una base "sin esquema"?**
Con `$jsonSchema` en `db.createCollection(..., { validator: {...},
validationLevel: "strict" })`. Probamos que un `insertOne` con
`region: "REGION_INEXISTENTE"` (fuera del `enum`) es rechazado con
`Document failed validation`.

## Fragmentación

**26. ¿Cómo garantizan que un `INSERT` con `region='NORTE'` termine físicamente en `pg-norte`?**
`paciente_global` está declarada `PARTITION BY LIST (region)` en el
coordinador, con `paciente_global_norte`/`paciente_global_sur` como
particiones que en realidad son `FOREIGN TABLE` vía `postgres_fdw`. El
motor enruta automáticamente el `INSERT` a la partición correcta; lo
verificamos consultando `pacientes_norte` directamente en `pg-norte`.

**27. ¿Por qué `paciente_global` no tiene `PRIMARY KEY`?**
Porque PostgreSQL no permite `UNIQUE`/`PRIMARY KEY` en una tabla
particionada si alguna partición es una `FOREIGN TABLE` — no puede
verificar unicidad a través de una conexión de red. La PK real vive en
cada fragmento físico (`pacientes_norte`/`pacientes_sur`).

**28. Expliquen las reglas de completitud, reconstrucción y disyunción en su diseño.**
Completitud: todo paciente cae en NORTE o SUR, no hay región sin
partición. Reconstrucción: `SELECT * FROM paciente_global` sin filtro
hace `Append` de ambos fragmentos (horizontal); `paciente_completo` hace
`JOIN` por `id_paciente` (vertical). Disyunción: horizontal, mutuamente
excluyente por `LIST`; vertical, cada columna vive en un solo fragmento
(público o financiero), nunca en ambos.

## Cloud / Costos

**29. ¿Por qué Atlas y no un contenedor Mongo local?**
El enunciado exige demostrar simultáneamente el modelo documental *y*
cloud computing real. Un Mongo local cumpliría lo primero pero no lo
segundo — no hay aprovisionamiento, IP allowlist, ni TLS real que
mostrar.

**30. Según su análisis de costos, ¿cuándo conviene más el self-hosted que Atlas?**
En nuestro dimensionamiento pequeño, Atlas M10 sale más barato que 3 VMs
propias en cuanto se contabilizan las horas de un DBA. El self-hosted
empieza a convenir cuando el volumen crece lo suficiente para necesitar
tiers altos de Atlas (M40+, con 3 nodos de voto), y ya se tiene personal
de operaciones contratado cuyo costo marginal por hora adicional es bajo
(ver `docs/03_costo_beneficio.md`, con cifras marcadas `[VERIFICAR]` para
confirmar el día de la entrega).
