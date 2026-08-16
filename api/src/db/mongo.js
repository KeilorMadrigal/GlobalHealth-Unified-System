// mongo.js — cliente hacia MongoDB Atlas (capa NoSQL en la nube).
//
// Conexión perezosa y cacheada: se abre una vez en el primer request que la
// necesite, y se reutiliza. serverSelectionTimeoutMS corto para que, si
// Atlas no es alcanzable, el endpoint falle rápido con un 503 en vez de
// colgarse (mismo criterio que connectionTimeoutMillis en pgMaster.js).

const { MongoClient } = require('mongodb');

let client;
let db;

async function getMongoDb() {
    if (db) return db;

    client = new MongoClient(process.env.MONGODB_URI, {
        serverSelectionTimeoutMS: 3000
    });
    await client.connect();
    db = client.db(process.env.MONGODB_DB);
    return db;
}

module.exports = { getMongoDb };
