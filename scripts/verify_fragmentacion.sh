#!/usr/bin/env bash
# Ejecuta la fragmentación horizontal y vertical de punta a punta y muestra
# evidencia en consola con un checklist OK/FALLO, igual que
# verify_replication.sh. Requiere pg-master, pg-norte y pg-sur arriba.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

PASS=0
FAIL=0

check() {
    if [ "$2" = "ok" ]; then
        echo "  [OK] $1"
        PASS=$((PASS+1))
    else
        echo "  [FALLO] $1"
        FAIL=$((FAIL+1))
    fi
}

echo "== 1) Fragmentación horizontal (sql/07_frag_horizontal.sql) =="
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" \
    -v superpass="$POSTGRES_SUPERUSER_PASSWORD" -v ON_ERROR_STOP=1 -q \
    -f /dev/stdin < sql/07_frag_horizontal.sql > /tmp/frag_horizontal.log 2>&1
if [ $? -eq 0 ]; then check "07_frag_horizontal.sql se ejecutó sin errores" ok; else check "07_frag_horizontal.sql se ejecutó sin errores" fail; fi

echo "== 2) region=NORTE aparece SOLO en pg-norte =="
EN_NORTE=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-norte \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGNORTE_DB" -tA -c "SELECT count(*) FROM pacientes_norte WHERE region <> 'NORTE';")
[ "$EN_NORTE" = "0" ] && check "pacientes_norte solo contiene region=NORTE" ok || check "pacientes_norte solo contiene region=NORTE" fail

echo "== 3) region=SUR aparece SOLO en pg-sur =="
EN_SUR=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-sur \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGSUR_DB" -tA -c "SELECT count(*) FROM pacientes_sur WHERE region <> 'SUR';")
[ "$EN_SUR" = "0" ] && check "pacientes_sur solo contiene region=SUR" ok || check "pacientes_sur solo contiene region=SUR" fail

echo "== 4) EXPLAIN con region='SUR' muestra partition pruning (un solo Foreign Scan) =="
PLAN=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -tA \
    -c "EXPLAIN (COSTS OFF) SELECT * FROM paciente_global WHERE region = 'SUR';")
echo "$PLAN" | grep -qi "Foreign Scan" && ! echo "$PLAN" | grep -qi "Append" \
    && check "filtro por region hace pruning (sin Append, un solo Foreign Scan)" ok \
    || check "filtro por region hace pruning (sin Append, un solo Foreign Scan)" fail

echo "== 5) Fragmentación vertical en pg-norte (sql/08_frag_vertical.sql) =="
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-norte \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGNORTE_DB" -q \
    -f /dev/stdin < sql/08_frag_vertical.sql > /tmp/frag_vertical_norte.log 2>&1
grep -q "permission denied for table paciente_financiero" /tmp/frag_vertical_norte.log \
    && check "pg-norte: dashboard_ro recibe permission denied en paciente_financiero" ok \
    || check "pg-norte: dashboard_ro recibe permission denied en paciente_financiero" fail

echo "== 6) Fragmentación vertical en pg-sur (sql/08_frag_vertical.sql) =="
docker exec -i -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-sur \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGSUR_DB" -q \
    -f /dev/stdin < sql/08_frag_vertical.sql > /tmp/frag_vertical_sur.log 2>&1
grep -q "permission denied for table paciente_financiero" /tmp/frag_vertical_sur.log \
    && check "pg-sur: dashboard_ro recibe permission denied en paciente_financiero" ok \
    || check "pg-sur: dashboard_ro recibe permission denied en paciente_financiero" fail

echo "== 7) Reconstrucción vertical sin pérdida ni duplicación (pg-norte) =="
RECON=$(docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-norte \
    psql -U "$POSTGRES_SUPERUSER" -d "$PGNORTE_DB" -tA \
    -c "SELECT (SELECT count(*) FROM paciente_publico) = (SELECT count(*) FROM paciente_financiero) AND (SELECT count(*) FROM paciente_publico) = (SELECT count(*) FROM paciente_completo);")
[ "$RECON" = "t" ] && check "paciente_completo reconstruye 1:1 sin pérdida ni duplicación" ok || check "paciente_completo reconstruye 1:1 sin pérdida ni duplicación" fail

echo
echo "== resumen: $PASS OK / $FAIL FALLO =="
[ "$FAIL" -eq 0 ]
