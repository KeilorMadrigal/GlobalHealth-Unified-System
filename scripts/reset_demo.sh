#!/usr/bin/env bash
# Devuelve TODO el entorno a un estado limpio y sembrado con un solo
# comando, para reintentar la demo si algo falla en vivo. Destruye los
# volúmenes de datos (no el código) y reconstruye desde cero.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

echo ">>> Bajando todo y borrando volúmenes de datos..."
docker compose down -v

echo ">>> Levantando maestro y réplica..."
docker compose up -d --build pg-master pg-replica
echo "    esperando a que pg-master esté healthy..."
until docker inspect --format='{{.State.Health.Status}}' pg-master 2>/dev/null | grep -q healthy; do sleep 1; done

echo ">>> Cargando capa MOR..."
for f in sql/01_mor_types.sql sql/02_mor_tables.sql sql/03_mor_crud.sql; do
    docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -f /dev/stdin < "$f"
done

echo ">>> Cargando capa XML/XSD..."
for f in sql/04_xml_registry.sql sql/05_xml_tables.sql; do
    docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
        psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -f /dev/stdin < "$f"
done
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -f /dev/stdin < xml/samples/insertar_muestras.sql

echo ">>> Levantando nodos de fragmentación..."
docker compose up -d --build pg-norte pg-sur
sleep 3
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" \
    -v superpass="$POSTGRES_SUPERUSER_PASSWORD" -v ON_ERROR_STOP=1 \
    -f /dev/stdin < sql/07_frag_horizontal.sql
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-norte \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGNORTE_DB" -f /dev/stdin < sql/08_frag_vertical.sql || true
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-sur \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGSUR_DB" -f /dev/stdin < sql/08_frag_vertical.sql || true

echo ">>> Re-aplicando GRANTs del rol de aplicación (globalhealth_app)..."
docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -c "
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${PGMASTER_USER};
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${PGMASTER_USER};
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ${PGMASTER_USER};
    "

echo ">>> Levantando API y web..."
docker compose up -d --build api web

echo ">>> Re-sembrando MongoDB Atlas (colecciones + datos)..."
docker run --rm -v "$(pwd)/mongo:/mongo" mongo:7 \
    mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" /mongo/01_schema_validators.js
docker run --rm -v "$(pwd)/mongo:/mongo" mongo:7 \
    mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" /mongo/02_seed.js

echo ">>> Verificando todo..."
bash scripts/verify_all.sh

echo ">>> Listo. Entorno reseteado y verificado."
