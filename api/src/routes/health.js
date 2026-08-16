const express = require('express');
const pgMaster = require('../db/pgMaster');
const { queryReadOnly } = require('../db/pgReplica');
const { getMongoDb } = require('../db/mongo');

const router = express.Router();

// GET /health -> estado INDIVIDUAL de master, réplica y Atlas (up/down por
// separado). Es el endpoint que alimenta el panel de semáforos de la Fase 7
// y la evidencia visual de la demo de caos (Fase 9).
router.get('/', async (req, res) => {
    const estado = { master: 'down', replica: 'down', atlas: 'down' };

    try {
        await pgMaster.query('SELECT 1');
        estado.master = 'up';
    } catch (err) {
        estado.master_error = err.message;
    }

    try {
        await queryReadOnly('SELECT 1');
        estado.replica = 'up';
    } catch (err) {
        estado.replica_error = err.message;
    }

    try {
        const db = await getMongoDb();
        await db.command({ ping: 1 });
        estado.atlas = 'up';
    } catch (err) {
        estado.atlas_error = err.message;
    }

    console.log(`[HEALTH] master=${estado.master} replica=${estado.replica} atlas=${estado.atlas}`);
    res.json(estado);
});

module.exports = router;
