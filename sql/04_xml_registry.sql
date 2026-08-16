-- ============================================================
-- Fase 3 — Catálogo de esquemas XSD + validación real en el motor
-- ============================================================
-- CONTEXTO CRÍTICO: PostgreSQL no implementa XMLVALIDATE ni
-- CREATE XML SCHEMA COLLECTION; el tipo 'xml' nativo solo garantiza
-- well-formedness. La cláusula anti-plagio del enunciado sanciona con la
-- pérdida total del apartado insertar XML sin vincularlo a un XSD
-- registrado EN LA BASE DE DATOS. Por eso la validación contra el esquema
-- se implementa como función del SERVIDOR en PL/Python3u con lxml (la
-- imagen de docker/postgres/Dockerfile ya la incluye), y se fuerza con un
-- trigger (ver 05_xml_tables.sql) — nunca queda en manos de la aplicación.

CREATE EXTENSION IF NOT EXISTS plpython3u;

-- ---------- Catálogo de esquemas ----------

CREATE TABLE xsd_registry (
    id                  serial PRIMARY KEY,
    nombre              text NOT NULL,
    version             text NOT NULL,
    contenido_xsd       xml NOT NULL,
    activo              boolean NOT NULL DEFAULT true,
    fecha_registro      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (nombre, version)
);
COMMENT ON TABLE xsd_registry IS 'Catálogo de plantillas XSD versionadas. Solo puede existir un activo=true por nombre a la vez (lo mantiene actualizar_xsd).';

-- ---------- Función de validación (el corazón de la Fase 3) ----------

CREATE FUNCTION validar_xml_contra_xsd(p_xml text, p_xsd text) RETURNS boolean AS $$
    # Usa lxml (no el 'xml' nativo de PostgreSQL, que solo revisa
    # well-formedness) para validar p_xml contra el esquema p_xsd. Si falla,
    # levanta plpy.error() con el mensaje EXACTO del validador: ese mensaje
    # es la evidencia que se muestra en la defensa cuando un XML se rechaza.
    from lxml import etree
    import io

    try:
        xsd_doc = etree.parse(io.BytesIO(p_xsd.encode('utf-8')))
        schema = etree.XMLSchema(xsd_doc)
    except Exception as e:
        plpy.error(f"XSD registrado inválido, no se pudo compilar como esquema: {e}")

    try:
        xml_doc = etree.parse(io.BytesIO(p_xml.encode('utf-8')))
    except Exception as e:
        plpy.error(f"XML mal formado: {e}")

    if not schema.validate(xml_doc):
        errores = "; ".join(str(err) for err in schema.error_log)
        plpy.error(f"XML no cumple el XSD registrado: {errores}")

    return True
$$ LANGUAGE plpython3u;
COMMENT ON FUNCTION validar_xml_contra_xsd(text, text) IS
    'Validación XSD real vía lxml.etree.XMLSchema, ejecutada dentro del motor. Usada por el trigger de expediente_clinico (05_xml_tables.sql).';

-- ---------- CRUD del catálogo: los 4 verbos que exige el enunciado ----------

-- 1) DECLARAR/REGISTRAR
CREATE PROCEDURE registrar_xsd(p_nombre text, p_version text, p_contenido xml) LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO xsd_registry (nombre, version, contenido_xsd, activo, fecha_registro)
    VALUES (p_nombre, p_version, p_contenido, true, now());
END;
$$;
COMMENT ON PROCEDURE registrar_xsd(text, text, xml) IS 'Registra una nueva versión de plantilla XSD como activa.';

-- 2) ACTUALIZAR (nueva versión activa, desactiva la anterior)
CREATE PROCEDURE actualizar_xsd(p_nombre text, p_version_nueva text, p_contenido xml) LANGUAGE plpgsql AS $$
BEGIN
    UPDATE xsd_registry SET activo = false WHERE nombre = p_nombre AND activo = true;
    INSERT INTO xsd_registry (nombre, version, contenido_xsd, activo, fecha_registro)
    VALUES (p_nombre, p_version_nueva, p_contenido, true, now());
END;
$$;
COMMENT ON PROCEDURE actualizar_xsd(text, text, xml) IS
    'Desactiva la versión activa actual y registra la nueva como activa. Los documentos ya insertados siguen referenciando su versión original (ver FK compuesta en expediente_clinico).';

-- 3) ELIMINAR (protegido si hay documentos dependientes)
CREATE PROCEDURE eliminar_xsd(p_nombre text, p_version text) LANGUAGE plpgsql AS $$
DECLARE
    v_dependientes integer;
BEGIN
    -- expediente_clinico se crea en 05_xml_tables.sql; esta referencia solo
    -- se resuelve en tiempo de ejecución (plpgsql no valida el cuerpo al
    -- crear el procedimiento, a diferencia de LANGUAGE sql).
    SELECT count(*) INTO v_dependientes
    FROM expediente_clinico
    WHERE xsd_nombre = p_nombre AND xsd_version = p_version;

    IF v_dependientes > 0 THEN
        RAISE EXCEPTION 'No se puede eliminar % versión %: % documento(s) dependiente(s)',
            p_nombre, p_version, v_dependientes;
    END IF;

    DELETE FROM xsd_registry WHERE nombre = p_nombre AND version = p_version;
END;
$$;
COMMENT ON PROCEDURE eliminar_xsd(text, text) IS 'Elimina una versión del catálogo solo si ningún expediente_clinico la referencia.';
