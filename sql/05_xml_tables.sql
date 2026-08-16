-- ============================================================
-- Fase 3 — Tabla de expedientes clínicos con validación forzada
-- ============================================================

CREATE TABLE expediente_clinico (
    id              serial PRIMARY KEY,
    id_paciente     integer NOT NULL,
    xsd_nombre      text NOT NULL,
    xsd_version     text NOT NULL,
    documento       xml NOT NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (xsd_nombre, xsd_version) REFERENCES xsd_registry (nombre, version)
);
COMMENT ON TABLE expediente_clinico IS 'documento se valida contra xsd_registry en CADA insert/update vía trigger, nunca en la aplicación.';

CREATE INDEX idx_expediente_paciente ON expediente_clinico (id_paciente);

-- ---------- Trigger de validación estricta ----------
-- Busca el XSD ACTIVO referenciado por la fila y valida documento contra
-- él. Si no hay ningún XSD activo con ese nombre/versión, también aborta:
-- nunca se permite insertar un expediente "huérfano" de esquema.

CREATE FUNCTION trg_validar_expediente() RETURNS trigger AS $$
DECLARE
    v_xsd_contenido text;
BEGIN
    SELECT contenido_xsd::text INTO v_xsd_contenido
    FROM xsd_registry
    WHERE nombre = NEW.xsd_nombre AND version = NEW.xsd_version AND activo = true;

    IF v_xsd_contenido IS NULL THEN
        RAISE EXCEPTION 'No existe un XSD ACTIVO registrado para % versión % (¿fue desactivado por actualizar_xsd?)',
            NEW.xsd_nombre, NEW.xsd_version;
    END IF;

    PERFORM validar_xml_contra_xsd(NEW.documento::text, v_xsd_contenido);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION trg_validar_expediente() IS 'Fuerza validación XSD estricta en cada INSERT/UPDATE de expediente_clinico. Ver validar_xml_contra_xsd en 04_xml_registry.sql.';

CREATE TRIGGER trg_expediente_validar
    BEFORE INSERT OR UPDATE ON expediente_clinico
    FOR EACH ROW EXECUTE FUNCTION trg_validar_expediente();
