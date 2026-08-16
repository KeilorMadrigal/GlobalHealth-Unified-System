const express = require('express');
const { ObjectId } = require('mongodb');
const { getMongoDb } = require('../db/mongo');

const router = express.Router();

// GET /api/telemetria/alertas -> pipeline de agregación de Atlas.
// Declarada ANTES de /:pacienteId para que 'alertas' no se interprete como
// un ObjectId de paciente.
router.get('/alertas', async (req, res) => {
    console.log('[ATLAS] GET /api/telemetria/alertas');
    try {
        const db = await getMongoDb();
        const resultado = await db.collection('sensor_logs').aggregate([
            { $match: { alerta: true } },
            { $group: { _id: '$sesion_id', total_alertas: { $sum: 1 } } },
            { $match: { total_alertas: { $gt: 5 } } },
            { $sort: { total_alertas: -1 } },
            { $limit: 20 }
        ]).toArray();
        res.json({ servido_por: 'ATLAS', alertas: resultado });
    } catch (err) {
        console.error('[ATLAS] error en GET /api/telemetria/alertas:', err.message);
        res.status(503).json({ error: 'Atlas no disponible', detalle: err.message });
    }
});

// GET /api/telemetria/:pacienteId -> $lookup contra MongoDB Atlas
// (reconstruye paciente -> sesiones -> últimos logs de cada sesión).
router.get('/:pacienteId', async (req, res) => {
    console.log('[ATLAS] GET /api/telemetria/:pacienteId');
    try {
        const db = await getMongoDb();
        const resultado = await db.collection('sesiones').aggregate([
            { $match: { paciente_id: new ObjectId(req.params.pacienteId) } },
            { $sort: { inicio: -1 } },
            {
                $lookup: {
                    from: 'sensor_logs',
                    localField: '_id',
                    foreignField: 'sesion_id',
                    as: 'logs_recientes',
                    pipeline: [{ $sort: { timestamp: -1 } }, { $limit: 50 }]
                }
            }
        ]).toArray();
        res.json({ servido_por: 'ATLAS', sesiones: resultado });
    } catch (err) {
        console.error('[ATLAS] error en GET /api/telemetria/:pacienteId:', err.message);
        res.status(503).json({ error: 'Atlas no disponible', detalle: err.message });
    }
});

module.exports = router;
