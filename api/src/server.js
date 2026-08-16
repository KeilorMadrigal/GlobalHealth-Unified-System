require('dotenv').config();

const express = require('express');
const cors = require('cors');

const personalRoutes = require('./routes/personal');
const dashboardRoutes = require('./routes/dashboard');
const expedientesRoutes = require('./routes/expedientes');
const pacientesRoutes = require('./routes/pacientes');
const telemetriaRoutes = require('./routes/telemetria');
const healthRoutes = require('./routes/health');

const app = express();
app.use(cors());
app.use(express.json({ limit: '2mb' })); // los expedientes XML pegados como texto pueden pesar

app.use('/api/personal', personalRoutes);
app.use('/api/dashboard', dashboardRoutes);
app.use('/api/expedientes', expedientesRoutes);
app.use('/api/pacientes', pacientesRoutes);
app.use('/api/telemetria', telemetriaRoutes);
app.use('/health', healthRoutes);

app.use((err, req, res, next) => {
    console.error('[API] error no manejado:', err);
    res.status(500).json({ error: 'Error interno del servidor' });
});

const PORT = process.env.API_PORT || 3000;
app.listen(PORT, () => {
    console.log(`GlobalHealth API escuchando en :${PORT}`);
});
