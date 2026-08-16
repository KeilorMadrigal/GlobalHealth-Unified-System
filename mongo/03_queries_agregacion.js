// ============================================================
// Fase 4 — Consultas y agregaciones de demostración
// ============================================================
// Ejecutar con:
//   mongosh "$MONGODB_URI/$MONGODB_DB?retryWrites=true&w=majority" mongo/03_queries_agregacion.js
//
// Cada bloque indica qué operador(es) demuestra.

// ------------------------------------------------------------
// (a) Operadores de comparación y lógicos: $gt, $lt, $in, $and, $or, $ne
// ------------------------------------------------------------

print("\n=== (a) comparación / lógicos ===");
printjson(
    db.sensor_logs.find({
        alerta: true,
        tipo_sensor: { $in: ["frecuencia_cardiaca", "saturacion_oxigeno"] },
        valor: { $gt: 0 }
    }).limit(3).toArray()
);

printjson(
    db.sesiones.find({
        $and: [
            { fin: { $ne: null } },
            { $or: [{ tipo: "telemedicina" }, { medico_id: "MED-1" }] }
        ]
    }).limit(3).toArray()
);

// ------------------------------------------------------------
// (b) $limit + $skip + $sort — paginación de logs
// ------------------------------------------------------------

print("\n=== (b) paginación (página 3 de frecuencia_cardiaca, 10 por página) ===");
printjson(
    db.sensor_logs.find({ tipo_sensor: "frecuencia_cardiaca" })
        .sort({ timestamp: -1 })
        .skip(20)
        .limit(10)
        .toArray()
);

// ------------------------------------------------------------
// (c) $lookup en dos saltos: sensor_logs -> sesiones -> pacientes
// Reconstruye la jerarquía abuelo-padre-hijo completa en un solo resultado.
// ------------------------------------------------------------

print("\n=== (c) $lookup de dos saltos (jerarquía completa) ===");
printjson(
    db.sensor_logs.aggregate([
        { $match: { alerta: true } },
        { $limit: 5 },
        {
            $lookup: {
                from: "sesiones",
                let: { sesionId: "$sesion_id" },
                pipeline: [
                    { $match: { $expr: { $eq: ["$_id", "$$sesionId"] } } },
                    {
                        $lookup: {
                            from: "pacientes",
                            localField: "paciente_id",
                            foreignField: "_id",
                            as: "paciente"
                        }
                    },
                    { $unwind: "$paciente" }
                ],
                as: "sesion"
            }
        },
        { $unwind: "$sesion" },
        {
            $project: {
                _id: 0,
                log: { timestamp: "$timestamp", tipo_sensor: "$tipo_sensor", valor: "$valor", alerta: "$alerta" },
                sesion: { tipo: "$sesion.tipo", inicio: "$sesion.inicio" },
                paciente: { nombre: "$sesion.paciente.nombre", region: "$sesion.paciente.region" }
            }
        }
    ]).toArray()
);

// ------------------------------------------------------------
// (d) Agregación analítica: promedio, máximo, desviación por tipo_sensor y
// por región. Incluye $bucket como ejemplo adicional de agregación.
// ------------------------------------------------------------

print("\n=== (d) promedio/max/stdDev por región y tipo_sensor ===");
printjson(
    db.sensor_logs.aggregate([
        {
            $lookup: {
                from: "sesiones",
                localField: "sesion_id",
                foreignField: "_id",
                as: "sesion"
            }
        },
        { $unwind: "$sesion" },
        {
            $lookup: {
                from: "pacientes",
                localField: "sesion.paciente_id",
                foreignField: "_id",
                as: "paciente"
            }
        },
        { $unwind: "$paciente" },
        {
            $group: {
                _id: { region: "$paciente.region", tipo_sensor: "$tipo_sensor" },
                promedio: { $avg: "$valor" },
                maximo: { $max: "$valor" },
                desviacion: { $stdDevPop: "$valor" },
                total_lecturas: { $sum: 1 }
            }
        },
        { $sort: { "_id.region": 1, "_id.tipo_sensor": 1 } }
    ]).toArray()
);

print("\n=== (d bis) $bucket de frecuencia_cardiaca ===");
printjson(
    db.sensor_logs.aggregate([
        { $match: { tipo_sensor: "frecuencia_cardiaca" } },
        {
            $bucket: {
                groupBy: "$valor",
                boundaries: [0, 60, 80, 100, 120, 300],
                default: "otro",
                output: { cantidad: { $sum: 1 } }
            }
        }
    ]).toArray()
);

// ------------------------------------------------------------
// (e) $unwind + $project + $addFields
// ------------------------------------------------------------

print("\n=== (e) unwind de notas + campo calculado ===");
printjson(
    db.sesiones.aggregate([
        { $unwind: "$notas" },
        { $addFields: { nota_longitud: { $strLenCP: "$notas.texto" } } },
        { $project: { _id: 0, paciente_id: 1, "notas.autor": 1, "notas.texto": 1, nota_longitud: 1 } },
        { $limit: 5 }
    ]).toArray()
);

// ------------------------------------------------------------
// (f) Sesiones con más de N alertas ($match tras $group)
// ------------------------------------------------------------

print("\n=== (f) sesiones con más de 5 alertas ===");
printjson(
    db.sensor_logs.aggregate([
        { $match: { alerta: true } },
        { $group: { _id: "$sesion_id", total_alertas: { $sum: 1 } } },
        { $match: { total_alertas: { $gt: 5 } } },
        { $sort: { total_alertas: -1 } },
        { $limit: 10 }
    ]).toArray()
);

// ------------------------------------------------------------
// (g) UPDATE complejo: $set con arrayFilters, $push, updateMany condicional
// ------------------------------------------------------------

print("\n=== (g) updates complejos ===");

const unaSesion = db.sesiones.findOne();

// $push a un arreglo embebido
const resPush = db.sesiones.updateOne(
    { _id: unaSesion._id },
    { $push: { notas: { autor: "MED-2", texto: "Revisión de seguimiento.", fecha: new Date(), revisada: false } } }
);
print(`push notas -> matched=${resPush.matchedCount} modified=${resPush.modifiedCount}`);

// $set con arrayFilters: marcar como revisadas solo las notas de MED-1
const resArrayFilters = db.sesiones.updateMany(
    { "notas.autor": "MED-1" },
    { $set: { "notas.$[n].revisada": true } },
    { arrayFilters: [{ "n.autor": "MED-1" }] }
);
print(`arrayFilters notas de MED-1 -> matched=${resArrayFilters.matchedCount} modified=${resArrayFilters.modifiedCount}`);

// updateMany con operador condicional ($cond / pipeline update)
const resCond = db.sesiones.updateMany(
    { tipo: "monitoreo" },
    [
        {
            $set: {
                prioridad: {
                    $cond: [{ $eq: ["$signos_vitales_resumen.promedio_spo2", null] }, "revisar", "normal"]
                }
            }
        }
    ]
);
print(`updateMany condicional (prioridad) -> matched=${resCond.matchedCount} modified=${resCond.modifiedCount}`);

// ------------------------------------------------------------
// (h) $merge — materialización de un resumen por sesión/sensor
// ------------------------------------------------------------

print("\n=== (h) $merge a resumen_sensores ===");
db.sensor_logs.aggregate([
    {
        $group: {
            _id: { sesion_id: "$sesion_id", tipo_sensor: "$tipo_sensor" },
            promedio: { $avg: "$valor" },
            alertas: { $sum: { $cond: ["$alerta", 1, 0] } }
        }
    },
    { $merge: { into: "resumen_sensores", whenMatched: "replace", whenNotMatched: "insert" } }
]);
print(`resumen_sensores materializada: ${db.resumen_sensores.countDocuments()} documentos`);
