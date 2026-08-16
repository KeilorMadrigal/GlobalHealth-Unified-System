const express = require('express');
const { queryReadOnly } = require('../db/pgReplica');

const router = express.Router();

// GET /api/pacientes?region= -> consulta sobre la tabla fragmentada
// (paciente_global, particionada por región vía postgres_fdw). Se lee
// desde la réplica igual que el resto de las lecturas; la fragmentación
// (Fase 5) y la separación lectura/escritura (Fase 6) son ortogonales.
router.get('/', async (req, res) => {
    const { region } = req.query;
    console.log(`[REPLICA] GET /api/pacientes?region=${region || ''}`);
    try {
        const result = region
            ? await queryReadOnly('SELECT * FROM paciente_global WHERE region = $1 ORDER BY id_paciente', [region])
            : await queryReadOnly('SELECT * FROM paciente_global ORDER BY id_paciente');
        res.json({ servido_por: 'REPLICA', pacientes: result.rows });
    } catch (err) {
        console.error('[REPLICA] error en GET /api/pacientes:', err.message);
        res.status(503).json({ error: 'Réplica no disponible', detalle: err.message });
    }
});

module.exports = router;
