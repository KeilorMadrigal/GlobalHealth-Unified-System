-- ============================================================
-- Fase 2 — Capa Objeto-Relacional: CRUD de demostración
-- ============================================================
-- Cada bloque indica qué requisito de la rúbrica cubre. Pensado para
-- ejecutarse completo (psql -f 03_mor_crud.sql) y también para leerse en
-- fragmentos durante la defensa.

-- ------------------------------------------------------------
-- CREATE — clínicas (tabla tipada, composición + nested table)
-- Requisito: CRUD sobre tabla tipada; constructores ROW() y arreglos.
-- ------------------------------------------------------------

INSERT INTO clinica (nombre, direccion, contacto, region) VALUES
(
    'Clínica San Rafael',
    ROW('Avenida Central 123', 'San José', 'CR', '10101')::tipo_direccion,
    ROW('contacto@sanrafael.cr', ARRAY['+506-2222-1111', '+506-2222-1112'])::tipo_contacto,
    'CENTRAL'
),
(
    'Hospital Metropolitano',
    ROW('6a Avenida 8-55 Zona 9', 'Ciudad de Guatemala', 'GT', '01009')::tipo_direccion,
    ROW('info@metropolitano.gt', ARRAY['+502-2366-0000'])::tipo_contacto,
    'GUATEMALA'
),
(
    'Clínica del Valle',
    ROW('Blvd. Morazán, Torre Alfa', 'Tegucigalpa', 'HN', '11101')::tipo_direccion,
    ROW('contacto@delvalle.hn', ARRAY['+504-2235-1000', '+504-2235-1001'])::tipo_contacto,
    'HONDURAS'
);

-- ------------------------------------------------------------
-- CREATE — equipo médico (tabla tipada, agregación)
-- ------------------------------------------------------------

INSERT INTO equipo_medico (serie, modelo, fecha_calibracion) VALUES
('EQ-0001', 'Monitor de signos vitales GE Dash 3000', '2026-01-15'),
('EQ-0002', 'Ecógrafo portátil Sonosite Edge II', '2026-03-01'),
('EQ-0003', 'Ventilador mecánico Puritan Bennett 980', '2025-11-20'),
('EQ-0004', 'Desfibrilador Philips HeartStart XL+', '2026-02-10');

INSERT INTO clinica_equipo (clinica_id, equipo_serie)
SELECT c.id, e.serie
FROM clinica c, equipo_medico e
WHERE c.nombre = 'Clínica San Rafael' AND e.serie IN ('EQ-0001', 'EQ-0002');

INSERT INTO clinica_equipo (clinica_id, equipo_serie)
SELECT c.id, e.serie
FROM clinica c, equipo_medico e
WHERE c.nombre = 'Hospital Metropolitano' AND e.serie IN ('EQ-0003', 'EQ-0004');

-- ------------------------------------------------------------
-- CREATE — jerarquía de personal (herencia INHERITS)
-- Requisito: INSERT con literales de tipo compuesto y de arreglo.
-- ------------------------------------------------------------

INSERT INTO medico (nombre, apellido, fecha_nacimiento, fecha_ingreso, documento_identidad, especialidades, credencial) VALUES
(
    'Ana', 'Rodríguez', '1985-04-12', '2015-06-01', '1-1111-1111',
    ARRAY[
        ROW('CARD', 'Cardiología', 12)::tipo_especialidad,
        ROW('MED-INT', 'Medicina Interna', 8)::tipo_especialidad
    ],
    ROW('COL-4521', '2015-05-20', true)::tipo_credencial
),
(
    'Carlos', 'Méndez', '1978-09-03', '2010-02-15', '2-2222-2222',
    ARRAY[
        ROW('CIR-GEN', 'Cirugía General', 18)::tipo_especialidad
    ],
    ROW('COL-2210', '2010-01-10', true)::tipo_credencial
);

INSERT INTO enfermero (nombre, apellido, fecha_nacimiento, fecha_ingreso, documento_identidad, turno, unidad) VALUES
('Laura', 'Jiménez', '1992-11-30', '2018-03-01', '3-3333-3333', 'nocturno', 'Emergencias'),
('Diego', 'Vargas', '1995-02-17', '2021-07-10', '4-4444-4444', 'matutino', 'UCI');

INSERT INTO tecnico_laboratorio (nombre, apellido, fecha_nacimiento, fecha_ingreso, documento_identidad, area_lab, certificaciones) VALUES
('Marta', 'Solís', '1990-06-05', '2019-09-01', '5-5555-5555', 'Hematología', ARRAY['ISO-15189', 'CAP']);

INSERT INTO personal_clinica (persona_id, clinica_id, cargo)
SELECT p.id, c.id, 'Médico de planta'
FROM persona p, clinica c
WHERE p.documento_identidad = '1-1111-1111' AND c.nombre = 'Clínica San Rafael';

INSERT INTO personal_clinica (persona_id, clinica_id, cargo)
SELECT p.id, c.id, 'Enfermería'
FROM persona p, clinica c
WHERE p.documento_identidad = '3-3333-3333' AND c.nombre = 'Clínica San Rafael';

-- ------------------------------------------------------------
-- READ (a) — acceso a atributos anidados de un tipo compuesto
-- Requisito: notación (columna).atributo.
-- ------------------------------------------------------------

SELECT
    nombre,
    (direccion).ciudad         AS ciudad,
    (direccion).pais           AS pais,
    (contacto).email           AS email,
    resumen_direccion(direccion) AS direccion_resumida
FROM clinica;

-- ------------------------------------------------------------
-- READ (b) — desarmar la nested table con unnest()
-- ------------------------------------------------------------

SELECT
    nombre_completo(m.*)   AS medico,
    (esp).codigo            AS especialidad_codigo,
    (esp).nombre            AS especialidad_nombre,
    (esp).anios_experiencia AS anios
FROM medico m, unnest(m.especialidades) AS esp
ORDER BY medico, anios DESC;

-- ------------------------------------------------------------
-- READ (c) — invocación de métodos del tipo (notación funcional)
-- ------------------------------------------------------------

SELECT
    nombre_completo(p.*)     AS nombre_completo,
    antiguedad_anios(p.*)    AS antiguedad_anios
FROM persona p
ORDER BY antiguedad_anios DESC;

SELECT
    nombre_completo(m.*)         AS medico,
    especialidad_principal(m.*)  AS especialidad_principal
FROM medico m;

SELECT
    c.nombre,
    capacidad_total(c.*) AS equipos_asignados
FROM clinica c
ORDER BY equipos_asignados DESC;

-- ------------------------------------------------------------
-- READ (d) — ONLY vs sin ONLY: efecto de la herencia
-- Requisito: demostrar la diferencia entre consultar solo la tabla padre
-- físicamente (ONLY) y consultar el árbol completo (comportamiento por
-- defecto de PostgreSQL en tablas con herencia).
-- ------------------------------------------------------------

SELECT count(*) AS filas_solo_en_persona FROM ONLY persona;
-- Esperado: 0, porque nunca se insertó directamente en 'persona'; todos los
-- registros viven en las tablas hijas (medico/enfermero/tecnico_laboratorio).

SELECT count(*) AS filas_persona_mas_hijas FROM persona;
-- Esperado: total de médicos + enfermeros + técnicos, porque sin ONLY
-- PostgreSQL hace UNION ALL automático con todas las tablas hijas.

-- ------------------------------------------------------------
-- UPDATE — atributo interno de un tipo compuesto
-- Requisito: modificar un campo anidado sin reescribir todo el valor.
-- ------------------------------------------------------------

UPDATE clinica
SET direccion.ciudad = 'Heredia'
WHERE nombre = 'Clínica San Rafael';

-- Verificación:
SELECT nombre, (direccion).ciudad FROM clinica WHERE nombre = 'Clínica San Rafael';

-- ------------------------------------------------------------
-- UPDATE — elemento de un arreglo (nested table)
-- Requisito: modificar un elemento sin reescribir el arreglo completo,
-- primero por subíndice y luego con array_replace como alternativa.
-- ------------------------------------------------------------

UPDATE medico
SET especialidades[1] = ROW('CARD', 'Cardiología Intervencionista', 13)::tipo_especialidad
WHERE documento_identidad = '1-1111-1111';

UPDATE medico
SET especialidades = array_replace(
    especialidades,
    (SELECT esp FROM unnest(especialidades) AS esp WHERE (esp).codigo = 'MED-INT'),
    ROW('MED-INT', 'Medicina Interna Avanzada', 9)::tipo_especialidad
)
WHERE documento_identidad = '1-1111-1111';

-- Verificación:
SELECT nombre_completo(m.*), especialidades FROM medico m WHERE documento_identidad = '1-1111-1111';

-- ------------------------------------------------------------
-- DELETE — composición vs agregación
-- ------------------------------------------------------------

-- Composición: al insertar y luego borrar una clínica de prueba, su
-- dirección (tipo_direccion embebido) desaparece con la fila; no hay nada
-- que "quede huérfano" porque nunca existió fuera de la clínica.
INSERT INTO clinica (nombre, direccion, contacto, region) VALUES (
    'Clínica de Prueba (composición)',
    ROW('Calle Efímera 1', 'Ciudad Demo', 'CR', '00000')::tipo_direccion,
    ROW('demo@efimera.cr', ARRAY[]::text[])::tipo_contacto,
    'DEMO'
);
DELETE FROM clinica WHERE nombre = 'Clínica de Prueba (composición)';
-- No hay tabla "direccion" que limpiar: la composición no deja rastro.

-- Agregación: borrar la asignación en clinica_equipo NO borra el equipo,
-- porque equipo_medico tiene vida propia (ON DELETE RESTRICT lo protege
-- de borrados en cascada desde la clínica).
DELETE FROM clinica_equipo
WHERE clinica_id = (SELECT id FROM clinica WHERE nombre = 'Hospital Metropolitano')
  AND equipo_serie = 'EQ-0004';

-- Verificación: el equipo sigue existiendo, solo cambió su disponibilidad.
SELECT * FROM equipo_medico WHERE serie = 'EQ-0004';
SELECT * FROM clinica_equipo WHERE equipo_serie = 'EQ-0004';
