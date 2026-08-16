#!/usr/bin/env bash
# Smoke test de toda la arquitectura (Fases 1 a 6). Requiere
# `docker compose up -d` ya corrido y el cluster de Atlas accesible.
# Imprime un checklist final con ✓/✗ por criterio de aceptación del plan.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

PASS=0
FAIL=0
declare -a FALLOS=()

check() {
    if [ "$2" = "ok" ]; then
        echo "  [✓] $1"
        PASS=$((PASS+1))
    else
        echo "  [✗] $1"
        FAIL=$((FAIL+1))
        FALLOS+=("$1")
    fi
}

pg() { docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -tA -c "$1" 2>&1; }
pgr() { docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-replica psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" -tA -c "$1" 2>&1; }

echo "================================================================"
echo " FASE 1 — Replicación"
echo "================================================================"
bash scripts/verify_replication.sh > /tmp/va_fase1.log 2>&1
[ $? -eq 0 ] && check "Fase 1: replicación (ver detalle en /tmp/va_fase1.log)" ok || check "Fase 1: replicación (ver detalle en /tmp/va_fase1.log)" fail

echo "================================================================"
echo " FASE 2 — Capa MOR"
echo "================================================================"
TIPO=$(pg "SELECT 1 FROM pg_type WHERE typname='tipo_clinica';")
[ "$TIPO" = "1" ] && check "tipo_clinica existe" ok || check "tipo_clinica existe" fail

ONLY=$(pg "SELECT count(*) FROM ONLY persona;")
TODOS=$(pg "SELECT count(*) FROM persona;")
[ "$ONLY" = "0" ] && [ "$TODOS" -gt "0" ] 2>/dev/null && check "herencia: ONLY persona=0, persona incluye hijas ($TODOS)" ok || check "herencia: ONLY persona=0, persona incluye hijas" fail

METODO=$(pg "SELECT nombre_completo(m.*) FROM medico m LIMIT 1;")
[ -n "$METODO" ] && check "método nombre_completo(medico) invocable" ok || check "método nombre_completo(medico) invocable" fail

echo "================================================================"
echo " FASE 3 — XML/XSD"
echo "================================================================"
EXP=$(pg "SELECT count(*) FROM expediente_clinico;")
[ "$EXP" -gt "0" ] 2>/dev/null && check "expediente_clinico tiene documentos válidos insertados ($EXP)" ok || check "expediente_clinico tiene documentos" fail

RECHAZO=$(pg "INSERT INTO expediente_clinico (id_paciente, xsd_nombre, xsd_version, documento) VALUES (999, 'expediente_clinico', 'v2', '<expediente xmlns=\"urn:globalhealth:expediente:v1\" version=\"1.0\"></expediente>');")
echo "$RECHAZO" | grep -qi "ERROR" && check "trigger rechaza XML inválido contra el XSD activo" ok || check "trigger rechaza XML inválido" fail

echo "================================================================"
echo " FASE 4 — MongoDB Atlas"
echo "================================================================"
MONGO_OK=$(timeout 30 docker run --rm mongo:7 mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" --quiet --eval "db.runCommand({ping:1}).ok" 2>&1)
[ "$MONGO_OK" = "1" ] && check "Atlas responde ping" ok || check "Atlas responde ping" fail

SENSOR_COUNT=$(timeout 30 docker run --rm mongo:7 mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" --quiet --eval "db.sensor_logs.countDocuments()" 2>&1)
[ "$SENSOR_COUNT" -gt "0" ] 2>/dev/null && check "sensor_logs tiene datos ($SENSOR_COUNT)" ok || check "sensor_logs tiene datos" fail

echo "================================================================"
echo " FASE 5 — Fragmentación"
echo "================================================================"
bash scripts/verify_fragmentacion.sh > /tmp/va_fase5.log 2>&1
[ $? -eq 0 ] && check "Fase 5: fragmentación (ver detalle en /tmp/va_fase5.log)" ok || check "Fase 5: fragmentación (ver detalle en /tmp/va_fase5.log)" fail

echo "================================================================"
echo " FASE 6 — Backend con separación física de conexiones"
echo "================================================================"
DOS_POOLS=$(grep -rc "new Pool" api/src/db/pgMaster.js api/src/db/pgReplica.js | awk -F: '{sum+=$2} END {print sum}')
[ "$DOS_POOLS" = "2" ] && check "dos objetos Pool distintos (pgMaster.js, pgReplica.js)" ok || check "dos objetos Pool distintos" fail

HEALTH=$(curl -s http://localhost:${API_PORT:-3000}/health)
echo "$HEALTH" | grep -q '"master"' && echo "$HEALTH" | grep -q '"replica"' && echo "$HEALTH" | grep -q '"atlas"' \
    && check "/health reporta master/replica/atlas por separado" ok \
    || check "/health reporta master/replica/atlas por separado" fail

echo
echo "================================================================"
echo " RESUMEN: $PASS OK / $FAIL FALLO"
echo "================================================================"
if [ "$FAIL" -gt 0 ]; then
    echo "Criterios en ✗:"
    for f in "${FALLOS[@]}"; do echo "  - $f"; done
fi
[ "$FAIL" -eq 0 ]
