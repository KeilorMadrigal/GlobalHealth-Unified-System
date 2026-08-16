-- ============================================================
-- Fase 3 — Intenta insertar las 7 muestras (3 válidas + 4 inválidas) y
-- muestra en pantalla el resultado de cada una. Pensado para la defensa en
-- vivo: cada línea RECHAZADO va con el mensaje EXACTO del validador XSD.
-- Requiere /xsd y /xml montados de solo lectura en pg-master (ver
-- docker-compose.yml) y que 04_xml_registry.sql / 05_xml_tables.sql ya se
-- hayan ejecutado.
-- ============================================================

-- Registrar v1 si todavía no está activo (no falla si ya existe).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM xsd_registry WHERE nombre = 'expediente_clinico' AND version = 'v1' AND activo = true
    ) THEN
        CALL registrar_xsd('expediente_clinico', 'v1', pg_read_file('/xsd/expediente_clinico_v1.xsd')::xml);
    END IF;
END $$;

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/valido_01.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (1, 'expediente_clinico', 'v1', v_doc);
    RAISE NOTICE 'valido_01.xml -> ACEPTADO';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'valido_01.xml -> RECHAZADO: %', SQLERRM;
END $$;

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/valido_02.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (2, 'expediente_clinico', 'v1', v_doc);
    RAISE NOTICE 'valido_02.xml -> ACEPTADO';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'valido_02.xml -> RECHAZADO: %', SQLERRM;
END $$;

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/valido_03.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (3, 'expediente_clinico', 'v1', v_doc);
    RAISE NOTICE 'valido_03.xml -> ACEPTADO';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'valido_03.xml -> RECHAZADO: %', SQLERRM;
END $$;

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/invalido_falta_elemento.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (4, 'expediente_clinico', 'v1', v_doc);
    RAISE NOTICE 'invalido_falta_elemento.xml -> ACEPTADO (¡no debería!)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'invalido_falta_elemento.xml -> RECHAZADO: %', SQLERRM;
END $$;

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/invalido_patron_cie10.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (5, 'expediente_clinico', 'v1', v_doc);
    RAISE NOTICE 'invalido_patron_cie10.xml -> ACEPTADO (¡no debería!)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'invalido_patron_cie10.xml -> RECHAZADO: %', SQLERRM;
END $$;

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/invalido_orden_roto.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (6, 'expediente_clinico', 'v1', v_doc);
    RAISE NOTICE 'invalido_orden_roto.xml -> ACEPTADO (¡no debería!)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'invalido_orden_roto.xml -> RECHAZADO: %', SQLERRM;
END $$;

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/invalido_sin_version.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (7, 'expediente_clinico', 'v1', v_doc);
    RAISE NOTICE 'invalido_sin_version.xml -> ACEPTADO (¡no debería!)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'invalido_sin_version.xml -> RECHAZADO: %', SQLERRM;
END $$;

-- ---------- Demostración de actualizar_xsd (v1 -> v2) ----------
-- v2 exige <alergias>, que ninguno de nuestros documentos v1 tiene. Un
-- documento que era válido en v1 debe ser RECHAZADO si se intenta insertar
-- referenciando v2.

CALL actualizar_xsd('expediente_clinico', 'v2', pg_read_file('/xsd/expediente_clinico_v2.xsd')::xml);

DO $$
DECLARE
    v_doc xml;
BEGIN
    v_doc := pg_read_file('/xml/samples/valido_01.xml')::xml;
    INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (1, 'expediente_clinico', 'v2', v_doc);
    RAISE NOTICE 'valido_01.xml contra v2 -> ACEPTADO (¡no debería!)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'valido_01.xml contra v2 -> RECHAZADO (esperado, falta <alergias>): %', SQLERRM;
END $$;

-- eliminar_xsd protegido: v1 sigue teniendo documentos dependientes.
DO $$
BEGIN
    CALL eliminar_xsd('expediente_clinico', 'v1');
    RAISE NOTICE 'eliminar_xsd v1 -> ELIMINADO (¡no debería, hay documentos dependientes!)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'eliminar_xsd v1 -> BLOQUEADO (esperado): %', SQLERRM;
END $$;
