// ============================================================
// Fase 4 — MongoDB Atlas: colecciones y validadores $jsonSchema
// ============================================================
// Ejecutar con:
//   mongosh "$MONGODB_URI/$MONGODB_DB?retryWrites=true&w=majority" mongo/01_schema_validators.js
//
// Jerarquía Abuelo -> Padre -> Hijo:
//   pacientes -> sesiones -> sensor_logs
//
// CRITERIO REFERENCIA vs EMBEBIDO (para la defensa):
//   - sensor_logs se modela por REFERENCIA (sesion_id) porque crece sin
//     límite (una sesión de monitoreo genera cientos de lecturas) y un
//     documento de MongoDB tiene un tope duro de 16 MB: embeberlas dentro
//     de 'sesiones' eventualmente reventaría ese límite y además haría
//     gigante cada lectura/escritura de la sesión completa solo para leer
//     sus metadatos.
//   - signos_vitales_resumen y notas SÍ van EMBEBIDOS dentro de 'sesiones'
//     porque son de baja cardinalidad, se leen siempre junto con la sesión,
//     y no crecen sin control (un resumen, unas pocas notas clínicas). Este
//     documento demuestra ambos criterios de diseño, no solo uno.

db.createCollection("pacientes", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["documento", "nombre", "region", "clinica_id"],
            properties: {
                documento: {
                    bsonType: "string",
                    description: "Documento de identidad, único por paciente."
                },
                nombre: { bsonType: "string" },
                region: {
                    enum: ["CENTRAL", "GUATEMALA", "HONDURAS"],
                    description: "Coincide con clinica.region de la capa MOR (PostgreSQL), para poder cruzar reportes."
                },
                clinica_id: {
                    bsonType: "int",
                    description: "Referencia lógica (no FK) al id de clinica en PostgreSQL."
                },
                fecha_nacimiento: { bsonType: "date" }
            }
        }
    },
    validationLevel: "strict"
});

db.createCollection("sesiones", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["paciente_id", "tipo", "inicio"],
            properties: {
                paciente_id: {
                    bsonType: "objectId",
                    description: "Referencia al padre (pacientes._id). No embebido: ver justificación arriba."
                },
                tipo: { enum: ["telemedicina", "monitoreo"] },
                inicio: { bsonType: "date" },
                fin: { bsonType: ["date", "null"] },
                medico_id: { bsonType: "string" },
                signos_vitales_resumen: {
                    bsonType: "object",
                    description: "EMBEBIDO: baja cardinalidad, se lee siempre junto con la sesión.",
                    properties: {
                        promedio_fc: { bsonType: ["double", "int", "null"] },
                        promedio_spo2: { bsonType: ["double", "int", "null"] },
                        ultima_actualizacion: { bsonType: ["date", "null"] }
                    }
                },
                notas: {
                    bsonType: "array",
                    description: "EMBEBIDO: crece lentamente (notas clínicas puntuales), no como sensor_logs.",
                    items: {
                        bsonType: "object",
                        required: ["autor", "texto", "fecha"],
                        properties: {
                            autor: { bsonType: "string" },
                            texto: { bsonType: "string" },
                            fecha: { bsonType: "date" },
                            revisada: { bsonType: "bool" }
                        }
                    }
                },
                prioridad: { bsonType: "string" }
            }
        }
    },
    validationLevel: "strict"
});

db.createCollection("sensor_logs", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["sesion_id", "timestamp", "tipo_sensor", "valor", "unidad", "alerta"],
            properties: {
                sesion_id: {
                    bsonType: "objectId",
                    description: "Referencia al padre (sesiones._id). Nunca embebido: ver justificación arriba."
                },
                timestamp: { bsonType: "date" },
                tipo_sensor: {
                    enum: [
                        "frecuencia_cardiaca",
                        "saturacion_oxigeno",
                        "temperatura",
                        "presion_sistolica",
                        "presion_diastolica"
                    ]
                },
                valor: { bsonType: ["double", "int"] },
                unidad: { bsonType: "string" },
                alerta: { bsonType: "bool" }
            }
        }
    },
    validationLevel: "strict"
});

// ---------- Índices ----------

// sensor_logs: consulta más frecuente es "logs de esta sesión, más recientes
// primero" (paginación en el visor de telemetría, Fase 7).
db.sensor_logs.createIndex(
    { sesion_id: 1, timestamp: -1 },
    { name: "idx_sensor_logs_sesion_timestamp" }
);

// sesiones: "sesiones de este paciente, más recientes primero" (dashboard).
db.sesiones.createIndex(
    { paciente_id: 1, inicio: -1 },
    { name: "idx_sesiones_paciente_inicio" }
);

// pacientes: el documento de identidad es la clave natural de negocio y
// debe ser único (equivalente al UNIQUE INDEX de persona.documento_identidad
// en la capa MOR).
db.pacientes.createIndex(
    { documento: 1 },
    { unique: true, name: "idx_pacientes_documento_unique" }
);

print("Colecciones y validadores creados.");
