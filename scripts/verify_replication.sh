#!/usr/bin/env bash
# Verifica de punta a punta que la replicación física maestro/esclavo funciona
# según los criterios de aceptación de la Fase 1 del plan. Pensado para
# correr desde la raíz del repo, con pg-master y pg-replica ya levantados.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

PASS=0
FAIL=0

check() {
    local desc="$1"
    if [ "$2" = "ok" ]; then
        echo "  [OK] $desc"
        PASS=$((PASS+1))
    else
        echo "  [FALLO] $desc"
        FAIL=$((FAIL+1))
    fi
}

echo "== 1) pg_stat_replication en el maestro =="
STATE=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -tA \
    -c "SELECT state FROM pg_stat_replication LIMIT 1;")
echo "  estado reportado: ${STATE:-<vacío>}"
[ "$STATE" = "streaming" ] && check "réplica en estado 'streaming'" ok || check "réplica en estado 'streaming'" fail

echo "== 2) pg_is_in_recovery() en la réplica =="
RECOVERY=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-replica \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -tA -c "SELECT pg_is_in_recovery();")
[ "$RECOVERY" = "t" ] && check "réplica reporta pg_is_in_recovery() = t" ok || check "réplica reporta pg_is_in_recovery() = t" fail

echo "== 3) escritura en maestro visible en réplica en < 2s =="
docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -q \
    -c "CREATE TABLE IF NOT EXISTS _verify_replicacion(id serial primary key, msg text, creado timestamptz default now());" \
    -c "INSERT INTO _verify_replicacion(msg) VALUES ('verify_replication.sh');"
sleep 1
COUNT=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-replica \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -tA \
    -c "SELECT count(*) FROM _verify_replicacion WHERE msg='verify_replication.sh';")
[ "$COUNT" = "1" ] && check "fila insertada en maestro llegó a la réplica en <2s" ok || check "fila insertada en maestro llegó a la réplica en <2s" fail

echo "== 4) INSERT directo en réplica debe fallar (read-only) =="
ERR=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-replica \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" \
    -c "INSERT INTO _verify_replicacion(msg) VALUES ('no debería insertarse');" 2>&1 || true)
echo "  $ERR"
echo "$ERR" | grep -q "cannot execute INSERT in a read-only transaction" \
    && check "réplica rechaza INSERT con el error esperado" ok \
    || check "réplica rechaza INSERT con el error esperado" fail

docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -q -c "DROP TABLE IF EXISTS _verify_replicacion;"

echo
echo "== resumen: $PASS OK / $FAIL FALLO =="
[ "$FAIL" -eq 0 ]
