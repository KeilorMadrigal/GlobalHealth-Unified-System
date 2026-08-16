const express = require('express');
const { queryReadOnly } = require('../db/pgReplica');

const router = express.Router();

// GET /api/dashboard/resumen -> consulta pesada agregada, SIEMPRE de la réplica
router.get('/resumen', async (req, res) => {
    console.log('[REPLICA] GET /api/dashboard/resumen');
    try {
        const [clinicas, personal, expedientes] = await Promise.all([
            queryReadOnly(`SELECT c.nombre, c.region, capacidad_total(c.*) AS equipos_asignados FROM clinica c ORDER BY c.nombre`),
            queryReadOnly(`SELECT count(*) AS total FROM persona`),
            queryReadOnly(`SELECT count(*) AS total FROM expediente_clinico`)
        ]);
        res.json({
            servido_por: 'REPLICA',
            clinicas: clinicas.rows,
            total_personal: Number(personal.rows[0].total),
            total_expedientes: Number(expedientes.rows[0].total)
        });
    } catch (err) {
        console.error('[REPLICA] error en GET /api/dashboard/resumen:', err.message);
        res.status(503).json({ error: 'Réplica no disponible', detalle: err.message });
    }
});

module.exports = router;
