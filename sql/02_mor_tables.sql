-- ============================================================
-- Fase 2 — Capa Objeto-Relacional: tablas
-- ============================================================

-- ---------- Herencia: jerarquía de personal ----------
-- persona -> medico / enfermero / tecnico_laboratorio (INHERITS)
--
-- El id se genera desde una secuencia COMPARTIDA por toda la jerarquía: al
-- declarar el DEFAULT en la tabla padre, las tablas hijas lo heredan
-- automáticamente (INHERITS propaga columnas y defaults, no constraints).
-- Así los id son únicos en toda la jerarquía aunque INHERITS no imponga una
-- PK única entre tablas hermanas a nivel de motor.

CREATE SEQUENCE persona_id_seq;

CREATE TABLE persona (
    id                      integer PRIMARY KEY DEFAULT nextval('persona_id_seq'),
    nombre                  text NOT NULL,
    apellido                text NOT NULL,
    fecha_nacimiento        date NOT NULL,
    fecha_ingreso           date NOT NULL DEFAULT current_date,
    documento_identidad     text NOT NULL
);
ALTER SEQUENCE persona_id_seq OWNED BY persona.id;
COMMENT ON TABLE persona IS 'Tabla base de la jerarquía de personal (herencia INHERITS, no tabla tipada).';

CREATE TABLE medico (
    especialidades  tipo_especialidad[] NOT NULL DEFAULT '{}',  -- nested table de tipo compuesto
    credencial      tipo_credencial NOT NULL,
    PRIMARY KEY (id)
) INHERITS (persona);
COMMENT ON TABLE medico IS 'Hija de persona vía INHERITS. especialidades es una nested table (arreglo de tipo compuesto).';

CREATE TABLE enfermero (
    turno   text NOT NULL CHECK (turno IN ('matutino', 'vespertino', 'nocturno')),
    unidad  text NOT NULL,
    PRIMARY KEY (id)
) INHERITS (persona);

CREATE TABLE tecnico_laboratorio (
    area_lab        text NOT NULL,
    certificaciones text[] DEFAULT '{}',
    PRIMARY KEY (id)
) INHERITS (persona);

CREATE UNIQUE INDEX idx_persona_documento ON persona (documento_identidad);

-- ---------- Tablas tipadas ----------
-- CREATE TABLE ... OF <tipo>: la tabla queda "atada" a un tipo compuesto ya
-- existente. No puede combinarse con INHERITS (de ahí que la jerarquía de
-- personal use herencia normal y estas dos usen tabla tipada).

CREATE SEQUENCE clinica_id_seq;

CREATE TABLE clinica OF tipo_clinica (
    PRIMARY KEY (id),
    id      WITH OPTIONS DEFAULT nextval('clinica_id_seq'),
    nombre  WITH OPTIONS NOT NULL
);
ALTER SEQUENCE clinica_id_seq OWNED BY clinica.id;
COMMENT ON TABLE clinica IS 'Tabla tipada (CREATE TABLE OF tipo_clinica). direccion es composición; equipo_medico se agrega vía clinica_equipo.';

CREATE TABLE equipo_medico OF tipo_equipo (
    PRIMARY KEY (serie)
);
COMMENT ON TABLE equipo_medico IS 'Tabla tipada (CREATE TABLE OF tipo_equipo). Existe independientemente de cualquier clínica (agregación).';

CREATE INDEX idx_clinica_region ON clinica (region);

-- ---------- Composición vs agregación ----------
--
-- COMPOSICIÓN ya está resuelta arriba: clinica.direccion es un atributo
-- embebido (tipo_direccion) que vive y muere con la fila de la clínica; no
-- existe fuera de ella y no requiere tabla ni FK propios.
--
-- AGREGACIÓN: clinica_equipo es la tabla puente que vincula clinica con
-- equipo_medico. El equipo tiene vida propia (puede existir sin estar
-- asignado a ninguna clínica, o reasignarse); por eso es un ON DELETE
-- RESTRICT hacia equipo_medico (no se borra el equipo por accidente) pero
-- ON DELETE CASCADE hacia clinica (al borrar la clínica solo desaparece la
-- asignación, nunca el equipo).

CREATE TABLE clinica_equipo (
    id                  serial PRIMARY KEY,
    clinica_id          integer NOT NULL REFERENCES clinica (id) ON DELETE CASCADE,
    equipo_serie        text NOT NULL REFERENCES equipo_medico (serie) ON DELETE RESTRICT,
    fecha_asignacion    date NOT NULL DEFAULT current_date,
    UNIQUE (clinica_id, equipo_serie)
);
COMMENT ON TABLE clinica_equipo IS 'Tabla puente que modela la AGREGACIÓN clinica <-> equipo_medico (equipos con vida propia).';

CREATE INDEX idx_clinica_equipo_clinica ON clinica_equipo (clinica_id);
CREATE INDEX idx_clinica_equipo_equipo ON clinica_equipo (equipo_serie);

-- ---------- Asignación de personal a clínicas ----------
-- TRAMPA REAL DE POSTGRESQL (no está en la lista de la sección 1 del plan,
-- se descubrió al ejecutar este script): una FK "REFERENCES persona(id)"
-- SOLO valida contra las filas físicamente almacenadas en la tabla persona,
-- no contra sus hijas por INHERITS. Como ningún médico/enfermero/técnico se
-- inserta jamás directamente en 'persona' (siempre en la tabla hija
-- correspondiente), una FK literal aquí rechazaría TODOS los inserts. Los
-- triggers tampoco se heredan entre tablas de la jerarquía, así que la
-- integridad referencial hay que resolverla a mano con triggers en cada
-- tabla involucrada, usando 'SELECT ... FROM persona' (sin ONLY) que sí
-- hace UNION ALL con las hijas.

CREATE TABLE personal_clinica (
    id                  serial PRIMARY KEY,
    persona_id          integer NOT NULL,  -- ver trigger trg_validar_persona_existe, no FK directa (ver nota arriba)
    clinica_id          integer NOT NULL REFERENCES clinica (id) ON DELETE CASCADE,
    cargo               text NOT NULL,
    fecha_asignacion    date NOT NULL DEFAULT current_date,
    UNIQUE (persona_id, clinica_id)
);

CREATE INDEX idx_personal_clinica_clinica ON personal_clinica (clinica_id);
CREATE INDEX idx_personal_clinica_persona ON personal_clinica (persona_id);

CREATE FUNCTION validar_persona_existe() RETURNS trigger AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM persona WHERE id = NEW.persona_id) THEN
        RAISE EXCEPTION 'persona_id % no existe en la jerarquía persona/medico/enfermero/tecnico_laboratorio', NEW.persona_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION validar_persona_existe() IS
    'Sustituto de la FK que INHERITS no permite: valida persona_id contra toda la jerarquía (SELECT sin ONLY).';

CREATE TRIGGER trg_validar_persona_existe
    BEFORE INSERT OR UPDATE ON personal_clinica
    FOR EACH ROW EXECUTE FUNCTION validar_persona_existe();

CREATE FUNCTION limpiar_personal_clinica_al_borrar() RETURNS trigger AS $$
BEGIN
    DELETE FROM personal_clinica WHERE persona_id = OLD.id;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION limpiar_personal_clinica_al_borrar() IS
    'Sustituto de ON DELETE CASCADE: se registra en CADA tabla hija porque un trigger en persona no se dispara al borrar directamente en medico/enfermero/tecnico_laboratorio.';

CREATE TRIGGER trg_limpiar_personal_clinica AFTER DELETE ON medico
    FOR EACH ROW EXECUTE FUNCTION limpiar_personal_clinica_al_borrar();
CREATE TRIGGER trg_limpiar_personal_clinica AFTER DELETE ON enfermero
    FOR EACH ROW EXECUTE FUNCTION limpiar_personal_clinica_al_borrar();
CREATE TRIGGER trg_limpiar_personal_clinica AFTER DELETE ON tecnico_laboratorio
    FOR EACH ROW EXECUTE FUNCTION limpiar_personal_clinica_al_borrar();

-- ============================================================
-- Métodos del tipo que dependen de las tablas de la jerarquía de personal
-- ============================================================
-- Van aquí (no en 01_mor_types.sql) porque 'persona' y 'medico' son tipos
-- fila de TABLA: solo existen después de CREATE TABLE. Intentar declarar
-- estas funciones antes fallaría con "type persona does not exist".

CREATE FUNCTION nombre_completo(p persona) RETURNS text AS $$
    SELECT p.nombre || ' ' || p.apellido;
$$ LANGUAGE sql IMMUTABLE;
COMMENT ON FUNCTION nombre_completo(persona) IS
    'Método del tipo persona (y por herencia de tipo, de medico/enfermero/tecnico_laboratorio). Invocar como nombre_completo(p) o (p).nombre_completo.';

CREATE FUNCTION antiguedad_anios(p persona) RETURNS integer AS $$
    SELECT extract(year FROM age(current_date, p.fecha_ingreso))::integer;
$$ LANGUAGE sql STABLE;
COMMENT ON FUNCTION antiguedad_anios(persona) IS
    'Método del tipo persona: años completos desde fecha_ingreso hasta hoy.';

CREATE FUNCTION especialidad_principal(m medico) RETURNS text AS $$
    SELECT (e).nombre
    FROM unnest(m.especialidades) AS e
    ORDER BY (e).anios_experiencia DESC
    LIMIT 1;
$$ LANGUAGE sql STABLE;
COMMENT ON FUNCTION especialidad_principal(medico) IS
    'Método del tipo medico: desarma la nested table especialidades y devuelve la de mayor experiencia.';

CREATE FUNCTION capacidad_total(c tipo_clinica) RETURNS bigint AS $$
    -- AGREGACIÓN: cuenta los equipos vinculados a la clínica en la tabla
    -- puente clinica_equipo. Los equipos existen independientemente de la
    -- clínica (ver equipo_medico); este método solo los cuenta.
    SELECT count(*) FROM clinica_equipo ce WHERE ce.clinica_id = c.id;
$$ LANGUAGE sql STABLE;
COMMENT ON FUNCTION capacidad_total(tipo_clinica) IS
    'Método del tipo tipo_clinica: cuenta el equipo médico asignado (agregación, ver clinica_equipo). Definido aquí, no en 01_mor_types.sql, porque LANGUAGE sql valida en CREATE FUNCTION que clinica_equipo ya exista.';

-- ---------- Permisos del rol de aplicación ----------
-- Las tablas se crean como el superusuario (postgres), no como
-- globalhealth_app: sin este GRANT, el backend (Fase 6, que se conecta
-- como globalhealth_app) recibe "permission denied" en todo. El ALTER
-- DEFAULT PRIVILEGES cubre además los objetos que se crean en fases
-- posteriores (XML en 03, fragmentación en 05), sin tener que repetir el
-- GRANT en cada archivo.

GRANT USAGE ON SCHEMA public TO globalhealth_app;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO globalhealth_app;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO globalhealth_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO globalhealth_app;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO globalhealth_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO globalhealth_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO globalhealth_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO globalhealth_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON ROUTINES TO globalhealth_app;
