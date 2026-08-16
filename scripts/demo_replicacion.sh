#!/usr/bin/env bash
# Guion de "chaos engineering" para la defensa en vivo (Fase 1 / Fase 9).
# Ejecuta paso a paso, con pausas, el escenario que exige la rúbrica:
# estado inicial -> escritura en master -> lectura en réplica ->
# docker stop pg-master -> lectura en réplica sigue funcionando ->
# intento de escritura falla controladamente -> docker start pg-master ->
# la replicación se recupera sola.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

pausa() {
    echo
    read -rp ">>> [ENTER para continuar] " _
    echo
}

titulo() {
    echo
    echo "================================================================"
    echo "  $1"
    echo "================================================================"
}

master_sql() {
    docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-master \
        psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" "$@"
}
replica_sql() {
    docker exec -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" pg-replica \
        psql -U "$POSTGRES_SUPERUSER" -d "$PGMASTER_DB" "$@"
}

titulo "1) Estado inicial: pg_stat_replication en el maestro"
master_sql -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
replica_sql -c "SELECT pg_is_in_recovery();"
pausa

titulo "2) Escritura en el maestro"
master_sql -c "CREATE TABLE IF NOT EXISTS _demo_replicacion(id serial primary key, msg text, creado timestamptz default now());"
master_sql -c "INSERT INTO _demo_replicacion(msg) VALUES ('escrito en el maestro a las ' || now());"
pausa

titulo "3) Lectura en la réplica (debe verse inmediatamente)"
replica_sql -c "SELECT * FROM _demo_replicacion ORDER BY id DESC LIMIT 5;"
pausa

titulo "4) CAOS: apagando pg-master (docker stop pg-master)"
docker stop pg-master
pausa

titulo "5) La réplica SIGUE respondiendo lecturas con el maestro caído"
replica_sql -c "SELECT * FROM _demo_replicacion ORDER BY id DESC LIMIT 5;"
pausa

titulo "6) Intento de escritura contra la réplica -> error controlado (read-only)"
replica_sql -c "INSERT INTO _demo_replicacion(msg) VALUES ('esto no debería insertarse');" || true
pausa

titulo "7) Recuperando el maestro (docker start pg-master)"
docker start pg-master
echo "Esperando a que el maestro acepte conexiones..."
until docker exec pg-master pg_isready -U "$POSTGRES_SUPERUSER" >/dev/null 2>&1; do sleep 1; done
sleep 2
pausa

titulo "8) La replicación se restablece sola, sin intervención manual"
master_sql -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
master_sql -c "INSERT INTO _demo_replicacion(msg) VALUES ('post-recuperación');"
sleep 1
replica_sql -c "SELECT * FROM _demo_replicacion ORDER BY id DESC LIMIT 5;"

titulo "Demo terminada. Limpieza de la tabla de demo."
master_sql -c "DROP TABLE IF EXISTS _demo_replicacion;"
