-- ============================================================
-- Fase 2 — Capa Objeto-Relacional: tipos compuestos y dominios
-- ============================================================
-- REGLA DURA: CREATE TABLE ... OF <tipo> e INHERITS son incompatibles en
-- PostgreSQL. Por eso este archivo separa la demostración:
--   - tipos compuestos + tablas TIPADAS para clinica y equipo_medico
--   - HERENCIA (INHERITS) para la jerarquía de personal, en 02_mor_tables.sql
-- Los "métodos" que dependen de las filas de persona/medico (que son tipos
-- de tabla, no tipos compuestos independientes) se definen al final de
-- 02_mor_tables.sql, DESPUÉS de que esas tablas existan: PostgreSQL exige
-- que el tipo referenciado en la firma de una función ya exista.

-- ---------- Dominios con CHECK ----------

CREATE DOMAIN email_valido AS text
    CHECK (VALUE ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');
COMMENT ON DOMAIN email_valido IS 'Refuerza formato de correo a nivel de tipo, reutilizable en cualquier columna/atributo.';

CREATE DOMAIN codigo_pais_ca AS char(2)
    CHECK (VALUE IN ('CR', 'GT', 'HN'));
COMMENT ON DOMAIN codigo_pais_ca IS 'Países centroamericanos atendidos por la red GlobalHealth en esta fase del proyecto.';

-- ---------- Tipos compuestos (atributos complejos anidados) ----------

CREATE TYPE tipo_direccion AS (
    calle           text,
    ciudad          text,
    pais            codigo_pais_ca,
    codigo_postal   text
);
COMMENT ON TYPE tipo_direccion IS 'Atributo compuesto anidado: se usa por COMPOSICIÓN dentro de tipo_clinica.';

CREATE TYPE tipo_contacto AS (
    email       email_valido,
    telefonos   text[]
);
COMMENT ON TYPE tipo_contacto IS 'Atributo compuesto con nested table (telefonos text[]) dentro de tipo_clinica.';

CREATE TYPE tipo_especialidad AS (
    codigo              text,
    nombre              text,
    anios_experiencia  smallint
);
COMMENT ON TYPE tipo_especialidad IS 'Elemento de la nested table medico.especialidades (arreglo de tipo compuesto).';

CREATE TYPE tipo_credencial AS (
    numero_colegiado    text,
    fecha_emision       date,
    vigente             boolean
);

CREATE TYPE tipo_equipo AS (
    serie               text,
    modelo              text,
    fecha_calibracion   date
);
COMMENT ON TYPE tipo_equipo IS 'Base de la tabla tipada equipo_medico (CREATE TABLE equipo_medico OF tipo_equipo).';

-- ---------- Tipo base de la tabla tipada 'clinica' ----------

CREATE TYPE tipo_clinica AS (
    id          integer,
    nombre      text,
    direccion   tipo_direccion,   -- COMPOSICIÓN: la dirección muere con la clínica
    contacto    tipo_contacto,
    region      text
);
COMMENT ON TYPE tipo_clinica IS 'Base de CREATE TABLE clinica OF tipo_clinica (tabla tipada, ver 02_mor_tables.sql).';

-- ---------- Métodos del tipo (notación funcional) ----------
-- En PostgreSQL un "método" de un tipo compuesto es una función cuyo primer
-- parámetro es ese tipo. Se invoca de dos formas equivalentes:
--   SELECT resumen_direccion(d)   -- notación de función
--   SELECT (d).resumen_direccion  -- SOLO funciona si el parámetro se llama
--                                  igual al campo buscado; para funciones con
--                                  nombre propio se usa la forma de función.
-- Ambas formas se demuestran en 03_mor_crud.sql.

CREATE FUNCTION resumen_direccion(d tipo_direccion) RETURNS text AS $$
    SELECT concat_ws(', ', d.calle, d.ciudad, d.pais, d.codigo_postal);
$$ LANGUAGE sql IMMUTABLE;
COMMENT ON FUNCTION resumen_direccion(tipo_direccion) IS
    'Método del tipo tipo_direccion: concatena los campos en una sola línea legible. Invocar como resumen_direccion(x) o (x).resumen_direccion.';

-- capacidad_total(tipo_clinica) se define en 02_mor_tables.sql, no aquí:
-- referencia la tabla clinica_equipo, y PostgreSQL SÍ valida en CREATE
-- FUNCTION ... LANGUAGE sql que las relaciones citadas en el cuerpo ya
-- existan (a diferencia de plpgsql, que solo revisa sintaxis). Crearla
-- antes de que exista clinica_equipo falla con "relation does not exist".
