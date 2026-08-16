// ============================================================
// Fase 4 — Seed de datos realistas
// ============================================================
// 30 pacientes (10 por región), 4-6 sesiones por paciente, 200-500
// sensor_logs por sesión, con ~5% de lecturas fuera de rango marcadas
// alerta:true. Usa ObjectId reales para las referencias (nunca strings).
//
// Ejecutar con:
//   mongosh "$MONGODB_URI/$MONGODB_DB?retryWrites=true&w=majority" mongo/02_seed.js

const REGIONES = ["CENTRAL", "GUATEMALA", "HONDURAS"];
const NOMBRES = [
    "Ana", "Carlos", "Laura", "Diego", "Marta", "Jorge", "Sofía", "Luis",
    "Elena", "Miguel", "Paula", "Andrés", "Camila", "Roberto", "Valeria"
];
const APELLIDOS = [
    "Rodríguez", "Méndez", "Jiménez", "Vargas", "Solís", "Castro", "Rojas",
    "Fernández", "Gómez", "Alvarado", "Chacón", "Herrera", "Morales", "Ramírez"
];

function elegir(lista) {
    return lista[Math.floor(Math.random() * lista.length)];
}

function fechaHaceDias(diasMax) {
    const ms = Date.now() - Math.floor(Math.random() * diasMax * 86400000);
    return new Date(ms);
}

db.pacientes.deleteMany({});
db.sesiones.deleteMany({});
db.sensor_logs.deleteMany({});

// ---------- Pacientes (abuelo) ----------

const pacientes = [];
for (let i = 0; i < 30; i++) {
    const region = REGIONES[i % 3];
    pacientes.push({
        _id: new ObjectId(),
        documento: `PAC-${String(i + 1).padStart(4, "0")}`,
        nombre: `${elegir(NOMBRES)} ${elegir(APELLIDOS)}`,
        region: region,
        clinica_id: (i % 3) + 1,
        fecha_nacimiento: fechaHaceDias(365 * 70)
    });
}
db.pacientes.insertMany(pacientes);
print(`Insertados ${pacientes.length} pacientes.`);

// ---------- Sesiones (padre) y sensor_logs (hijo) ----------

const TIPOS_SESION = ["telemedicina", "monitoreo"];
const TIPOS_SENSOR = [
    { tipo: "frecuencia_cardiaca", unidad: "lpm", min: 55, max: 100 },
    { tipo: "saturacion_oxigeno", unidad: "%", min: 94, max: 100 },
    { tipo: "temperatura", unidad: "°C", min: 36.0, max: 37.5 },
    { tipo: "presion_sistolica", unidad: "mmHg", min: 100, max: 130 },
    { tipo: "presion_diastolica", unidad: "mmHg", min: 60, max: 85 }
];

let totalSesiones = 0;
let totalLogs = 0;

for (const paciente of pacientes) {
    const numSesiones = 4 + Math.floor(Math.random() * 3); // 4-6

    for (let s = 0; s < numSesiones; s++) {
        const inicio = fechaHaceDias(180);
        const tipo = elegir(TIPOS_SESION);
        const duracionMin = 15 + Math.floor(Math.random() * 90);
        const fin = new Date(inicio.getTime() + duracionMin * 60000);
        const sesionId = new ObjectId();

        const numLogs = 200 + Math.floor(Math.random() * 301); // 200-500
        const logs = [];
        let sumaFc = 0, cuentaFc = 0;
        let sumaSpo2 = 0, cuentaSpo2 = 0;

        for (let l = 0; l < numLogs; l++) {
            const sensor = elegir(TIPOS_SENSOR);
            const rango = sensor.max - sensor.min;
            const fueraDeRango = Math.random() < 0.05; // ~5% de alertas

            let valor;
            if (fueraDeRango) {
                valor = Math.random() < 0.5
                    ? sensor.min - Math.random() * rango * 0.3
                    : sensor.max + Math.random() * rango * 0.3;
            } else {
                valor = sensor.min + Math.random() * rango;
            }
            valor = Math.round(valor * 10) / 10;
            const alerta = valor < sensor.min || valor > sensor.max;
            const ts = new Date(inicio.getTime() + Math.floor((l / numLogs) * duracionMin * 60000));

            if (sensor.tipo === "frecuencia_cardiaca") { sumaFc += valor; cuentaFc++; }
            if (sensor.tipo === "saturacion_oxigeno") { sumaSpo2 += valor; cuentaSpo2++; }

            logs.push({
                _id: new ObjectId(),
                sesion_id: sesionId,
                timestamp: ts,
                tipo_sensor: sensor.tipo,
                valor: valor,
                unidad: sensor.unidad,
                alerta: alerta
            });
        }

        db.sensor_logs.insertMany(logs, { ordered: false });
        totalLogs += logs.length;

        db.sesiones.insertOne({
            _id: sesionId,
            paciente_id: paciente._id,
            tipo: tipo,
            inicio: inicio,
            fin: fin,
            medico_id: `MED-${1 + Math.floor(Math.random() * 5)}`,
            signos_vitales_resumen: {
                promedio_fc: cuentaFc ? Math.round((sumaFc / cuentaFc) * 10) / 10 : null,
                promedio_spo2: cuentaSpo2 ? Math.round((sumaSpo2 / cuentaSpo2) * 10) / 10 : null,
                ultima_actualizacion: fin
            },
            notas: [
                {
                    autor: `MED-${1 + Math.floor(Math.random() * 5)}`,
                    texto: "Sesión registrada automáticamente por el seed de demo.",
                    fecha: fin,
                    revisada: false
                }
            ]
        });
        totalSesiones++;
    }
}

print(`Insertadas ${totalSesiones} sesiones y ${totalLogs} sensor_logs.`);
