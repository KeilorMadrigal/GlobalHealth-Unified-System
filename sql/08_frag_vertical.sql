-- ============================================================
-- Fase 5 — Fragmentación vertical
-- ============================================================
-- A diferencia de 07_frag_horizontal.sql, este script NO se ejecuta en el
-- coordinador: se ejecuta DOS VECES, una vez conectado directamente a cada
-- nodo (son fragmentos independientes, cada uno con su copia local de
-- paciente_publico/paciente_financiero). Vía docker exec para evitar
-- depender de los puertos publicados al host (ver nota de puertos en
-- 07_frag_horizontal.sql):
--
--   docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-norte \
--     psql -U postgres -d globalhealth_norte -f /dev/stdin < sql/08_frag_vertical.sql
--   docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-sur \
--     psql -U postgres -d globalhealth_sur -f /dev/stdin < sql/08_frag_vertical.sql
--
-- Regla de corrección de la fragmentación vertical: ambas tablas comparten
-- EXACTAMENTE la misma PK (id_paciente). La reconstrucción es un JOIN por
-- esa llave; sin esa igualdad de PK no hay manera correcta de recomponer
-- la fila original.

DROP VIEW IF EXISTS paciente_completo;
DROP TABLE IF EXISTS paciente_financiero;
DROP TABLE IF EXISTS paciente_publico;

CREATE TABLE paciente_publico (
    id_paciente     integer PRIMARY KEY,
    nombre          text NOT NULL,
    telefono        text,
    email           text,
    direccion       text
);
COMMENT ON TABLE paciente_publico IS 'Fragmento vertical: datos de bajo riesgo, lectura frecuente (dashboard).';

CREATE TABLE paciente_financiero (
    id_paciente     integer PRIMARY KEY REFERENCES paciente_publico (id_paciente) ON DELETE CASCADE,
    num_seguro      text NOT NULL,
    plan            text NOT NULL,
    saldo           numeric(12, 2) NOT NULL DEFAULT 0,
    tarjeta_hash    text NOT NULL
);
COMMENT ON TABLE paciente_financiero IS 'Fragmento vertical: datos sensibles, distinto régimen de confidencialidad y acceso restringido.';

-- ---------- Seed ----------

INSERT INTO paciente_publico (id_paciente, nombre, telefono, email, direccion) VALUES
(1, 'Ana Rodríguez', '+506-8888-0001', 'ana@example.com', 'San José, CR'),
(2, 'Laura Jiménez', '+506-8888-0002', 'laura@example.com', 'Heredia, CR');

INSERT INTO paciente_financiero (id_paciente, num_seguro, plan, saldo, tarjeta_hash) VALUES
(1, 'SEG-1001', 'Plan Oro', 1500.00, 'a1b2c3d4e5f6'),
(2, 'SEG-1002', 'Plan Plata', 320.50, 'f6e5d4c3b2a1');

-- ---------- Vista de reconstrucción ----------

CREATE VIEW paciente_completo AS
SELECT
    pu.id_paciente, pu.nombre, pu.telefono, pu.email, pu.direccion,
    pf.num_seguro, pf.plan, pf.saldo, pf.tarjeta_hash
FROM paciente_publico pu
JOIN paciente_financiero pf ON pf.id_paciente = pu.id_paciente;

-- Reconstrucción sin pérdida ni duplicación: los tres conteos deben coincidir.
\echo '--- Verificación lossless: publico / financiero / vista reconstruida ---'
SELECT
    (SELECT count(*) FROM paciente_publico)    AS total_publico,
    (SELECT count(*) FROM paciente_financiero) AS total_financiero,
    (SELECT count(*) FROM paciente_completo)   AS total_reconstruido;

-- ---------- Rol de solo lectura pública ----------

DROP ROLE IF EXISTS dashboard_ro;
CREATE ROLE dashboard_ro LOGIN PASSWORD 'changeme_dashboard';
GRANT USAGE ON SCHEMA public TO dashboard_ro;
GRANT SELECT ON paciente_publico TO dashboard_ro;
-- Deliberadamente SIN GRANT sobre paciente_financiero ni paciente_completo
-- (la vista hace JOIN con financiero, así que tampoco debería ser legible).

\echo '--- SET ROLE dashboard_ro: debe poder leer paciente_publico ---'
SET ROLE dashboard_ro;
SELECT * FROM paciente_publico;

\echo '--- SET ROLE dashboard_ro: debe FALLAR con permission denied sobre paciente_financiero ---'
SELECT * FROM paciente_financiero;
-- Esperado: ERROR: permission denied for table paciente_financiero

RESET ROLE;
