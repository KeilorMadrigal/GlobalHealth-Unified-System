#!/usr/bin/env bash
# Siembra datos de demo en PostgreSQL (MOR + XML, Fases 2/3) y MongoDB
# Atlas (Fase 4), asumiendo que el esquema ya existe (DDL ya corrido).
# Para reconstruir todo desde cero, usar scripts/reset_demo.sh en su lugar.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

echo ">>> Sembrando capa MOR (sql/03_mor_crud.sql)..."
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -f /dev/stdin < sql/03_mor_crud.sql

echo ">>> Sembrando expedientes XML (xml/samples/insertar_muestras.sql)..."
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -f /dev/stdin < xml/samples/insertar_muestras.sql

echo ">>> Sembrando MongoDB Atlas (mongo/02_seed.js)..."
docker run --rm -v "$(pwd)/mongo:/mongo" mongo:7 \
    mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" /mongo/02_seed.js

echo ">>> Listo."
