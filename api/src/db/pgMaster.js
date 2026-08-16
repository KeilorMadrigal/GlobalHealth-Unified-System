// pgMaster.js — SOLO ESCRITURAS.
//
// RESTRICCIÓN DURA (ver CLAUDE.md): este pool y el de pgReplica.js son dos
// objetos Pool físicamente separados, con host/puerto/credenciales propios,
// en archivos distintos. Nunca unificar en un solo pool con un `if`.
//
// connectionTimeoutMillis corto a propósito: si pg-master está caído, un
// endpoint de escritura debe fallar en ~2s con un 503 controlado, no dejar
// al profesor esperando 30s frente al proyector durante la demo de caos.

const { Pool } = require('pg');

const pgMaster = new Pool({
    host: process.env.PGMASTER_HOST,
    port: Number(process.env.PGMASTER_PORT || 5432),
    database: process.env.PGMASTER_DB,
    user: process.env.PGMASTER_USER,
    password: process.env.PGMASTER_PASSWORD,
    connectionTimeoutMillis: Number(process.env.PG_CONNECT_TIMEOUT_MS || 2000),
    max: 10
});

pgMaster.on('error', (err) => {
    console.error('[MASTER] error inesperado en el pool:', err.message);
});

module.exports = pgMaster;
