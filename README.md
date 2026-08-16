# GlobalHealth Unified System

Proyecto final integrador — Bases de Datos Avanzadas.

Arquitectura híbrida: PostgreSQL (Objeto-Relacional + XML/XSD) con
replicación maestro/esclavo y fragmentación horizontal/vertical,
MongoDB Atlas (NoSQL en la nube), y una API con separación física de
conexiones de lectura/escritura.

Ver `PLAN_GlobalHealth_Proyecto_Final.md` para el plan de ejecución
completo por fases, y `CLAUDE.md` para las restricciones duras del
proyecto.

## Estado

El proyecto avanza por fases. Ver checklist de aceptación en el plan.

## Requisitos

- Docker + Docker Compose
- Node.js 20+ (para desarrollo local de la API fuera de contenedor)
- Cuenta de MongoDB Atlas (capa NoSQL en la nube, Fase 4)

## Arranque rápido

```bash
cp .env.example .env
# completar .env con credenciales reales (nunca commitear)
docker compose up -d
```

## Estructura

```
globalhealth/
├── docker-compose.yml
├── docker/            # Dockerfiles e init scripts de PostgreSQL
├── sql/                # DDL/DML: tipos MOR, XML/XSD, fragmentación
├── xsd/                # Esquemas XSD versionados
├── xml/samples/        # Documentos XML válidos e inválidos de demo
├── mongo/               # Scripts de Atlas: validators, seed, agregaciones
├── api/                 # Backend Node.js + Express
├── web/                 # Interfaz mínima de consumo
├── docs/                 # Arquitectura, fragmentación, costo/beneficio, defensa
└── scripts/              # Verificación y demo en vivo
```
