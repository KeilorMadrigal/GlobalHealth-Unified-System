const express = require('express');
const pgMaster = require('../db/pgMaster');
const { queryReadOnly } = require('../db/pgReplica');

const router = express.Router();

function esErrorDeConexion(err) {
    return err.code === 'ETIMEDOUT' || err.code === 'ECONNREFUSED' || /timeout/i.test(err.message || '');
}

// POST /api/expedientes -> inserta XML, dispara validación XSD (trigger en
// el motor); si el validador rechaza el documento, 422 con su mensaje.
router.post('/', async (req, res) => {
    const { id_paciente, xsd_nombre = 'expediente_clinico', xsd_version = 'v1', documento } = req.body;
    console.log('[MASTER] POST /api/expedientes');

    if (!documento) {
        return res.status(400).json({ error: 'documento (XML) es obligatorio' });
    }

    try {
        const result = await pgMaster.query(
            `INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento)
             VALUES ($1, $2, $3, $4) RETURNING id`,
            [id_paciente, xsd_nombre, xsd_version, documento]
        );
        res.status(201).json(result.rows[0]);
    } catch (err) {
        if (esErrorDeConexion(err)) {
            console.error('[MASTER] no disponible:', err.message);
            return res.status(503).json({ error: 'Master no disponible: escrituras suspendidas' });
        }
        // El trigger trg_expediente_validar levanta esto vía plpy.error();
        // err.message trae el mensaje EXACTO del validador XSD.
        console.log('[MASTER] expediente rechazado por el validador XSD');
        res.status(422).json({ error: 'Documento rechazado por el validador XSD', detalle: err.message });
    }
});

// GET /api/expedientes/:id/diagnosticos -> xmltable() sobre la réplica
router.get('/:id/diagnosticos', async (req, res) => {
    console.log('[REPLICA] GET /api/expedientes/:id/diagnosticos');
    try {
        const result = await queryReadOnly(
            `SELECT d.*
             FROM expediente_clinico ec,
                  XMLTABLE(
                    XMLNAMESPACES('urn:globalhealth:expediente:v1' AS gh),
                    '/gh:expediente/gh:diagnosticos/gh:diagnostico' PASSING ec.documento
                    COLUMNS
                        codigo              text PATH 'gh:codigo',
                        descripcion         text PATH 'gh:descripcion',
                        fecha               date PATH 'gh:fecha',
                        medico_responsable  text PATH 'gh:medicoResponsable'
                  ) AS d
             WHERE ec.id = $1`,
            [req.params.id]
        );
        res.json({ servido_por: 'REPLICA', diagnosticos: result.rows });
    } catch (err) {
        console.error('[REPLICA] error en GET /api/expedientes/:id/diagnosticos:', err.message);
        res.status(503).json({ error: 'Réplica no disponible', detalle: err.message });
    }
});

module.exports = router;
