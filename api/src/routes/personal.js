const express = require('express');
const pgMaster = require('../db/pgMaster');
const { queryReadOnly } = require('../db/pgReplica');

const router = express.Router();

function esErrorDeConexion(err) {
    return err.code === 'ETIMEDOUT' || err.code === 'ECONNREFUSED' || /timeout/i.test(err.message || '');
}

// POST /api/personal -> escribe en master (MOR: tabla tipada/herencia)
router.post('/', async (req, res) => {
    const { tipo, nombre, apellido, fecha_nacimiento, documento_identidad } = req.body;
    console.log(`[MASTER] POST /api/personal (tipo=${tipo})`);

    try {
        let result;
        if (tipo === 'medico') {
            const { especialidades = [], credencial } = req.body;
            result = await pgMaster.query(
                `INSERT INTO medico (nombre, apellido, fecha_nacimiento, fecha_ingreso, documento_identidad, especialidades, credencial)
                 VALUES ($1, $2, $3, current_date, $4,
                         (SELECT array_agg(ROW(e->>'codigo', e->>'nombre', (e->>'anios_experiencia')::smallint)::tipo_especialidad)
                          FROM jsonb_array_elements($5::jsonb) e),
                         ROW($6->>'numero_colegiado', ($6->>'fecha_emision')::date, ($6->>'vigente')::boolean)::tipo_credencial)
                 RETURNING id`,
                [nombre, apellido, fecha_nacimiento, documento_identidad, JSON.stringify(especialidades), credencial]
            );
        } else if (tipo === 'enfermero') {
            const { turno, unidad } = req.body;
            result = await pgMaster.query(
                `INSERT INTO enfermero (nombre, apellido, fecha_nacimiento, fecha_ingreso, documento_identidad, turno, unidad)
                 VALUES ($1, $2, $3, current_date, $4, $5, $6) RETURNING id`,
                [nombre, apellido, fecha_nacimiento, documento_identidad, turno, unidad]
            );
        } else if (tipo === 'tecnico_laboratorio') {
            const { area_lab, certificaciones = [] } = req.body;
            result = await pgMaster.query(
                `INSERT INTO tecnico_laboratorio (nombre, apellido, fecha_nacimiento, fecha_ingreso, documento_identidad, area_lab, certificaciones)
                 VALUES ($1, $2, $3, current_date, $4, $5, $6) RETURNING id`,
                [nombre, apellido, fecha_nacimiento, documento_identidad, area_lab, certificaciones]
            );
        } else {
            return res.status(400).json({ error: "tipo debe ser 'medico', 'enfermero' o 'tecnico_laboratorio'" });
        }
        res.status(201).json(result.rows[0]);
    } catch (err) {
        if (esErrorDeConexion(err)) {
            console.error('[MASTER] no disponible:', err.message);
            return res.status(503).json({ error: 'Master no disponible: escrituras suspendidas' });
        }
        console.error('[MASTER] error en POST /api/personal:', err.message);
        res.status(400).json({ error: err.message });
    }
});

// GET /api/personal -> lee de réplica
router.get('/', async (req, res) => {
    console.log('[REPLICA] GET /api/personal');
    try {
        const result = await queryReadOnly(`
            SELECT
                p.id,
                nombre_completo(p.*) AS nombre_completo,
                antiguedad_anios(p.*) AS antiguedad_anios,
                CASE
                    WHEN m.id IS NOT NULL THEN 'medico'
                    WHEN e.id IS NOT NULL THEN 'enfermero'
                    WHEN t.id IS NOT NULL THEN 'tecnico_laboratorio'
                END AS tipo
            FROM persona p
            LEFT JOIN medico m ON m.id = p.id
            LEFT JOIN enfermero e ON e.id = p.id
            LEFT JOIN tecnico_laboratorio t ON t.id = p.id
            ORDER BY p.id
        `);
        res.json({ servido_por: 'REPLICA', datos: result.rows });
    } catch (err) {
        console.error('[REPLICA] error en GET /api/personal:', err.message);
        res.status(503).json({ error: 'Réplica no disponible', detalle: err.message });
    }
});

module.exports = router;
