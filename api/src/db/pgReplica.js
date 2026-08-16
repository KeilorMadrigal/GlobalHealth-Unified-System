// pgReplica.js — SOLO LECTURAS.
//
// RESTRICCIÓN DURA (ver CLAUDE.md): pool físicamente separado de
// pgMaster.js. Además de que el motor ya rechaza escrituras en la réplica
// (cannot execute INSERT in a read-only transaction), queryReadOnly()
// bloquea la sentencia ANTES de enviarla: es defensa en profundidad, para
// fallar rápido y con un mensaje de la aplicación, no depender solo del
// error del motor.

const { Pool } = require('pg');

const pgReplica = new Pool({
    host: process.env.PGREPLICA_HOST,
    port: Number(process.env.PGREPLICA_PORT || 5432),
    database: process.env.PGREPLICA_DB,
    user: process.env.PGREPLICA_USER,
    password: process.env.PGREPLICA_PASSWORD,
    connectionTimeoutMillis: Number(process.env.PG_CONNECT_TIMEOUT_MS || 2000),
    max: 10
});

pgReplica.on('error', (err) => {
    console.error('[REPLICA] error inesperado en el pool:', err.message);
});

const SENTENCIA_ESCRITURA = /^\s*(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER|CREATE|CALL)\b/i;

async function queryReadOnly(text, params) {
    if (SENTENCIA_ESCRITURA.test(text)) {
        throw new Error(
            `pgReplica.queryReadOnly: sentencia de escritura bloqueada antes de llegar a la réplica: "${text.trim().slice(0, 60)}..."`
        );
    }
    return pgReplica.query(text, params);
}

module.exports = { pool: pgReplica, queryReadOnly };
