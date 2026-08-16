-- ============================================================
-- Fase 3 — CRUD sobre porciones internas del XML
-- ============================================================
-- Requiere /xsd montado de solo lectura en el contenedor (ver
-- docker-compose.yml, servicio pg-master) para poder leer el XSD real con
-- pg_read_file() en vez de pegarlo como literal gigante en este script.

-- ---------- Registro del esquema v1 (declarar/registrar) ----------

CALL registrar_xsd('expediente_clinico', 'v1', pg_read_file('/xsd/expediente_clinico_v1.xsd')::xml);

-- ---------- INSERT de dos expedientes válidos ----------

INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES
(
    1, 'expediente_clinico', 'v1',
    $$<?xml version="1.0" encoding="UTF-8"?>
<expediente xmlns="urn:globalhealth:expediente:v1" version="1.0">
  <paciente id="PAC-0001">
    <nombre>Ana Rodríguez</nombre>
    <fechaNacimiento>1985-04-12</fechaNacimiento>
  </paciente>
  <diagnosticos>
    <diagnostico>
      <codigo>J45.0</codigo>
      <descripcion>Asma predominantemente alérgica</descripcion>
      <fecha>2026-01-10</fecha>
      <medicoResponsable>Dr. Carlos Méndez</medicoResponsable>
    </diagnostico>
    <diagnostico>
      <codigo>I10</codigo>
      <descripcion>Hipertensión esencial</descripcion>
      <fecha>2026-02-01</fecha>
      <medicoResponsable>Dr. Carlos Méndez</medicoResponsable>
    </diagnostico>
  </diagnosticos>
  <tratamientos>
    <tratamiento>
      <medicamento>Salbutamol</medicamento>
      <dosis>100mcg</dosis>
      <frecuencia>Cada 6 horas si hay síntomas</frecuencia>
    </tratamiento>
  </tratamientos>
  <firmaDigital>3f7a9c8e1b2d4f6a8c0e2b4d6f8a0c2e</firmaDigital>
</expediente>$$
),
(
    2, 'expediente_clinico', 'v1',
    $$<?xml version="1.0" encoding="UTF-8"?>
<expediente xmlns="urn:globalhealth:expediente:v1" version="1.0">
  <paciente id="PAC-0002">
    <nombre>Carlos Méndez</nombre>
    <fechaNacimiento>1978-09-03</fechaNacimiento>
  </paciente>
  <diagnosticos>
    <diagnostico>
      <codigo>E11</codigo>
      <descripcion>Diabetes mellitus tipo 2</descripcion>
      <fecha>2026-03-05</fecha>
      <medicoResponsable>Dra. Ana Rodríguez</medicoResponsable>
    </diagnostico>
  </diagnosticos>
  <tratamientos>
  </tratamientos>
  <firmaDigital>9a1c3e5f7b9d1f3a5c7e9b1d3f5a7c9e</firmaDigital>
</expediente>$$
);

-- ------------------------------------------------------------
-- READ (a) — xpath(): extracción de nodos individuales
-- Namespace: nuestro XSD define targetNamespace, así que toda consulta
-- xpath necesita el mapeo de prefijo -> URI como tercer argumento.
-- ------------------------------------------------------------

SELECT
    id,
    (xpath('/gh:expediente/gh:paciente/gh:nombre/text()', documento,
           ARRAY[ARRAY['gh', 'urn:globalhealth:expediente:v1']]))[1]::text AS nombre_paciente,
    (xpath('/gh:expediente/@version', documento,
           ARRAY[ARRAY['gh', 'urn:globalhealth:expediente:v1']]))[1]::text AS version_esquema
FROM expediente_clinico;

-- ------------------------------------------------------------
-- READ (b) — xmltable(): proyectar los <diagnostico> como filas
-- ------------------------------------------------------------

SELECT ec.id AS expediente_id, d.*
FROM expediente_clinico ec,
     XMLTABLE(
        XMLNAMESPACES('urn:globalhealth:expediente:v1' AS gh),
        '/gh:expediente/gh:diagnosticos/gh:diagnostico' PASSING ec.documento
        COLUMNS
            codigo              text PATH 'gh:codigo',
            descripcion         text PATH 'gh:descripcion',
            fecha               date PATH 'gh:fecha',
            medico_responsable  text PATH 'gh:medicoResponsable'
     ) AS d;

-- ------------------------------------------------------------
-- READ (c) — xpath_exists() como predicado en WHERE
-- ------------------------------------------------------------

SELECT id, id_paciente
FROM expediente_clinico
WHERE xpath_exists(
    '/gh:expediente/gh:diagnosticos/gh:diagnostico[gh:codigo="E11"]',
    documento,
    ARRAY[ARRAY['gh', 'urn:globalhealth:expediente:v1']]
);

-- ------------------------------------------------------------
-- UPDATE de un nodo interno
-- ------------------------------------------------------------
-- PostgreSQL no tiene un DML tipo modify() de XQuery Update Facility (a
-- diferencia de SQL Server). La alternativa "de libro" con contrib/xml2
-- (xslt_process) es una extensión legacy que ni siquiera viene compilada
-- en la imagen oficial de postgres:16. La solución pragmática y
-- consistente con el resto de la Fase 3: reutilizar PL/Python3u + lxml (ya
-- necesario para la validación XSD) para localizar el nodo por XPath,
-- reemplazar su contenido y reescribir el documento completo con un UPDATE
-- real -> eso hace que vuelva a pasar por el trigger de validación.

CREATE FUNCTION actualizar_nodo_xml(p_id integer, p_xpath text, p_valor_nuevo text) RETURNS xml AS $$
    # p_xpath es de uso interno/administrativo (no exponer tal cual a un
    # endpoint público sin sanearlo primero).
    from lxml import etree
    import io

    plan = plpy.prepare("SELECT documento::text AS doc FROM expediente_clinico WHERE id = $1", ["integer"])
    rows = plpy.execute(plan, [p_id])
    if len(rows) == 0:
        plpy.error(f"No existe expediente_clinico con id {p_id}")

    tree = etree.parse(io.BytesIO(rows[0]['doc'].encode('utf-8')))
    ns = {'gh': 'urn:globalhealth:expediente:v1'}

    nodos = tree.xpath(p_xpath, namespaces=ns)
    if len(nodos) == 0:
        plpy.error(f"XPath '{p_xpath}' no encontró ningún nodo en el expediente {p_id}")

    for nodo in nodos:
        nodo.text = p_valor_nuevo

    nuevo_xml = etree.tostring(tree, encoding='unicode')

    update_plan = plpy.prepare(
        "UPDATE expediente_clinico SET documento = $1 WHERE id = $2 RETURNING documento",
        ["xml", "integer"]
    )
    resultado = plpy.execute(update_plan, [nuevo_xml, p_id])
    return resultado[0]['documento']
$$ LANGUAGE plpython3u;
COMMENT ON FUNCTION actualizar_nodo_xml(integer, text, text) IS
    'Reemplaza el texto del/los nodo(s) que matchean p_xpath. Al hacer un UPDATE real, dispara trg_expediente_validar de nuevo.';

-- Demostración: corregir la descripción de un diagnóstico.
SELECT actualizar_nodo_xml(
    1,
    '//gh:diagnostico[gh:codigo="I10"]/gh:descripcion',
    'Hipertensión arterial esencial, controlada'
);

-- Verificación: vuelve a pasar por el trigger, el documento sigue siendo válido.
SELECT (xpath('//gh:diagnostico[gh:codigo="I10"]/gh:descripcion/text()', documento,
       ARRAY[ARRAY['gh', 'urn:globalhealth:expediente:v1']]))[1]::text
FROM expediente_clinico WHERE id = 1;

-- ------------------------------------------------------------
-- DELETE de un subnodo (quitar un <diagnostico> por código)
-- ------------------------------------------------------------

CREATE FUNCTION eliminar_diagnostico(p_id integer, p_codigo text) RETURNS xml AS $$
    from lxml import etree
    import io

    plan = plpy.prepare("SELECT documento::text AS doc FROM expediente_clinico WHERE id = $1", ["integer"])
    rows = plpy.execute(plan, [p_id])
    if len(rows) == 0:
        plpy.error(f"No existe expediente_clinico con id {p_id}")

    tree = etree.parse(io.BytesIO(rows[0]['doc'].encode('utf-8')))
    ns = {'gh': 'urn:globalhealth:expediente:v1'}

    # $codigo como variable XPath (no interpolación de strings) para evitar
    # inyección de XPath si p_codigo viniera de un input externo.
    diagnosticos = tree.xpath(
        "//gh:diagnostico[gh:codigo=$codigo]", namespaces=ns, codigo=p_codigo
    )
    if len(diagnosticos) == 0:
        plpy.error(f"No se encontró ningún diagnóstico con código {p_codigo} en el expediente {p_id}")

    for d in diagnosticos:
        d.getparent().remove(d)

    nuevo_xml = etree.tostring(tree, encoding='unicode')

    update_plan = plpy.prepare(
        "UPDATE expediente_clinico SET documento = $1 WHERE id = $2 RETURNING documento",
        ["xml", "integer"]
    )
    resultado = plpy.execute(update_plan, [nuevo_xml, p_id])
    return resultado[0]['documento']
$$ LANGUAGE plpython3u;
COMMENT ON FUNCTION eliminar_diagnostico(integer, text) IS
    'Quita un <diagnostico> por código y reescribe el documento con UPDATE (vuelve a validar contra el XSD).';

-- Demostración: el expediente 1 tiene 2 diagnósticos (J45.0, I10); borrar
-- uno sigue siendo válido porque diagnosticos exige minOccurs=1, no más.
SELECT eliminar_diagnostico(1, 'I10');

-- Verificación: ya no aparece I10, J45.0 sigue.
SELECT ec.id, d.codigo
FROM expediente_clinico ec,
     XMLTABLE(
        XMLNAMESPACES('urn:globalhealth:expediente:v1' AS gh),
        '/gh:expediente/gh:diagnosticos/gh:diagnostico' PASSING ec.documento
        COLUMNS codigo text PATH 'gh:codigo'
     ) AS d
WHERE ec.id = 1;

-- Demostración de que SIGUE pasando por el trigger: intentar borrar el
-- ÚNICO diagnóstico restante debe ser rechazado, porque el XSD exige
-- diagnosticos/diagnostico con minOccurs="1" y el documento resultante
-- quedaría sin ninguno.
SELECT eliminar_diagnostico(1, 'J45.0');
-- Esperado: ERROR con el mensaje de lxml indicando que falta el elemento
-- <diagnostico> requerido por el esquema.
