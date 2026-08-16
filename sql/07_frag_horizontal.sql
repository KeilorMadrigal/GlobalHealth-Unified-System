-- ============================================================
-- Fase 5 — Fragmentación horizontal (postgres_fdw + particiones)
-- ============================================================
-- Ejecutar vía docker exec DENTRO de la red globalhealth-net, para evitar
-- depender de los puertos publicados al host (en Windows, el 5432 del host
-- puede chocar con un PostgreSQL nativo ya instalado -> autenticación
-- fallida contra el servicio equivocado, no contra el contenedor):
--
--   docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
--     psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" \
--     -v superpass="$POSTGRES_SUPERUSER_PASSWORD" -v ON_ERROR_STOP=1 \
--     -f /dev/stdin < sql/07_frag_horizontal.sql
--
-- El script salta de nodo con \c usando los hostnames DNS internos de
-- Docker (pg-norte, pg-sur, pg-master) para crear primero la tabla física
-- en cada fragmento remoto, y termina en el coordinador configurando FDW.
-- PGPASSWORD ya está en el entorno del cliente, así que \c no necesita
-- repetir la contraseña; la contraseña SÍ hay que escribirla dentro del
-- CREATE USER MAPPING porque esa credencial la usa el SERVIDOR (pg-master)
-- cuando abre sus propias conexiones salientes a pg-norte/pg-sur, no tiene
-- relación con la sesión de este cliente.

-- ---------- 1) Tabla física en pg-norte ----------

\c "dbname=globalhealth_norte host=pg-norte port=5432 user=postgres"

DROP TABLE IF EXISTS pacientes_norte;
CREATE TABLE pacientes_norte (
    id_paciente     integer NOT NULL,
    nombre          text NOT NULL,
    documento       text NOT NULL,
    region          text NOT NULL,
    CONSTRAINT pacientes_norte_region_check CHECK (region = 'NORTE'),
    PRIMARY KEY (id_paciente, region)
);
COMMENT ON TABLE pacientes_norte IS 'Fragmento horizontal físico: solo pacientes de la región NORTE viven aquí.';

-- ---------- 2) Tabla física en pg-sur ----------

\c "dbname=globalhealth_sur host=pg-sur port=5432 user=postgres"

DROP TABLE IF EXISTS pacientes_sur;
CREATE TABLE pacientes_sur (
    id_paciente     integer NOT NULL,
    nombre          text NOT NULL,
    documento       text NOT NULL,
    region          text NOT NULL,
    CONSTRAINT pacientes_sur_region_check CHECK (region = 'SUR'),
    PRIMARY KEY (id_paciente, region)
);
COMMENT ON TABLE pacientes_sur IS 'Fragmento horizontal físico: solo pacientes de la región SUR viven aquí.';

-- ---------- 3) De vuelta en el coordinador (pg-master) ----------

\c "dbname=globalhealth host=pg-master port=5432 user=postgres"

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

CREATE SERVER IF NOT EXISTS nodo_norte
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'pg-norte', port '5432', dbname 'globalhealth_norte');
    -- 'pg-norte' es el hostname DNS interno de Docker: la conexión FDW la
    -- abre el proceso de pg-master DENTRO de la red globalhealth-net, no
    -- pasa por localhost ni por los puertos publicados al host.

CREATE SERVER IF NOT EXISTS nodo_sur
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'pg-sur', port '5432', dbname 'globalhealth_sur');

-- CREATE USER MAPPING IF NOT EXISTS es sintaxis nativa (no hace falta un DO
-- block): importante, porque las variables de psql (:'var') NO se
-- interpolan dentro de bloques $$ ... $$, solo en SQL plano como este.
CREATE USER MAPPING IF NOT EXISTS FOR postgres SERVER nodo_norte
    OPTIONS (user 'postgres', password :'superpass');
CREATE USER MAPPING IF NOT EXISTS FOR postgres SERVER nodo_sur
    OPTIONS (user 'postgres', password :'superpass');

-- El backend (Fase 6) consulta paciente_global como globalhealth_app, no
-- como postgres: sin su propia USER MAPPING, el fan-out fallaría con "no
-- user mapping found for user \"globalhealth_app\"" en cuanto la consulta
-- intente cruzar hacia pg-norte/pg-sur.
CREATE USER MAPPING IF NOT EXISTS FOR globalhealth_app SERVER nodo_norte
    OPTIONS (user 'postgres', password :'superpass');
CREATE USER MAPPING IF NOT EXISTS FOR globalhealth_app SERVER nodo_sur
    OPTIONS (user 'postgres', password :'superpass');

-- TRAMPA REAL DE POSTGRESQL (descubierta al ejecutar este script, no
-- documentada en la sección 1 del plan): una tabla particionada NO puede
-- tener índices UNIQUE/PRIMARY KEY si alguna de sus particiones va a ser
-- una FOREIGN TABLE, porque el motor no puede verificar unicidad a través
-- de una conexión de red. Por eso paciente_global NO lleva PRIMARY KEY; la
-- unicidad de id_paciente se sigue garantizando en cada fragmento físico
-- (pacientes_norte/pacientes_sur SÍ tienen su propia PK local).
DROP TABLE IF EXISTS paciente_global CASCADE;
CREATE TABLE paciente_global (
    id_paciente     integer NOT NULL,
    nombre          text NOT NULL,
    documento       text NOT NULL,
    region          text NOT NULL
) PARTITION BY LIST (region);
COMMENT ON TABLE paciente_global IS 'Vista unificada del coordinador: cada partición es en realidad una FOREIGN TABLE hacia pg-norte o pg-sur. Sin PK propia (ver nota arriba); la PK vive en cada fragmento físico.';

DROP FOREIGN TABLE IF EXISTS paciente_global_norte;
DROP FOREIGN TABLE IF EXISTS paciente_global_sur;

CREATE FOREIGN TABLE paciente_global_norte (
    id_paciente     integer NOT NULL,
    nombre          text NOT NULL,
    documento       text NOT NULL,
    region          text NOT NULL
) SERVER nodo_norte OPTIONS (table_name 'pacientes_norte');

CREATE FOREIGN TABLE paciente_global_sur (
    id_paciente     integer NOT NULL,
    nombre          text NOT NULL,
    documento       text NOT NULL,
    region          text NOT NULL
) SERVER nodo_sur OPTIONS (table_name 'pacientes_sur');

ALTER TABLE paciente_global ATTACH PARTITION paciente_global_norte FOR VALUES IN ('NORTE');
ALTER TABLE paciente_global ATTACH PARTITION paciente_global_sur FOR VALUES IN ('SUR');

-- ---------- 4) Demostraciones ----------

\echo '--- INSERT enrutado automáticamente por región ---'
INSERT INTO paciente_global (id_paciente, nombre, documento, region) VALUES
(1, 'Ana Rodríguez', 'PAC-0001', 'NORTE'),
(2, 'Carlos Méndez', 'PAC-0002', 'SUR'),
(3, 'Laura Jiménez', 'PAC-0003', 'NORTE'),
(4, 'Diego Vargas', 'PAC-0004', 'SUR');

\echo '--- EXPLAIN: SELECT global (sin filtro) -> Foreign Scan en AMBOS nodos ---'
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM paciente_global;

\echo '--- EXPLAIN: filtro por region=SUR -> partition pruning, SOLO Foreign Scan a pg-sur ---'
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM paciente_global WHERE region = 'SUR';

\echo '--- EXPLAIN: filtro que no usa la clave de partición -> vuelve a tocar ambos nodos ---'
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM paciente_global WHERE nombre LIKE 'A%';
-- Comparar el plan anterior con el de region='SUR': sin filtrar por la
-- clave de partición, el planificador no puede descartar ningún fragmento
-- y el costo (número de Foreign Scan) es mayor.

\echo '--- Verificación física: contenido real en cada nodo remoto ---'

\c "dbname=globalhealth_norte host=pg-norte port=5432 user=postgres"
\echo '>>> pg-norte (debe tener SOLO a Ana y Laura):'
SELECT * FROM pacientes_norte ORDER BY id_paciente;

\c "dbname=globalhealth_sur host=pg-sur port=5432 user=postgres"
\echo '>>> pg-sur (debe tener SOLO a Carlos y Diego):'
SELECT * FROM pacientes_sur ORDER BY id_paciente;

\c "dbname=globalhealth host=pg-master port=5432 user=postgres"
