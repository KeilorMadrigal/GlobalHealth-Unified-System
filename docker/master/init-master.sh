#!/bin/bash
# Se ejecuta UNA sola vez, durante la inicialización de pg-master (Docker
# solo corre docker-entrypoint-initdb.d/* cuando PGDATA está vacío). Deja el
# maestro listo para streaming replication: aplica la config de replicación,
# crea el rol 'replicador' y su replication slot, y crea el rol de aplicación
# que usarán tanto el maestro como (por copia física) la réplica.
set -euo pipefail

echo ">>> [init-master] aplicando configuración de replicación a postgresql.conf"
cat /docker-entrypoint-initdb.d/postgresql.conf >> "$PGDATA/postgresql.conf"

echo ">>> [init-master] instalando pg_hba.conf con acceso de replicación"
cp /docker-entrypoint-initdb.d/pg_hba.conf "$PGDATA/pg_hba.conf"

echo ">>> [init-master] creando rol de replicación '${PG_REPLICATION_USER}' y slot '${PG_REPLICATION_SLOT}'"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_REPLICATION_USER}') THEN
        CREATE ROLE ${PG_REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${PG_REPLICATION_PASSWORD}';
      END IF;
    END
    \$\$;

    SELECT pg_create_physical_replication_slot('${PG_REPLICATION_SLOT}')
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_replication_slots WHERE slot_name = '${PG_REPLICATION_SLOT}'
    );
EOSQL

echo ">>> [init-master] creando rol de aplicación '${PGMASTER_USER}' (lectura/escritura)"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PGMASTER_USER}') THEN
        CREATE ROLE ${PGMASTER_USER} WITH LOGIN PASSWORD '${PGMASTER_PASSWORD}';
      END IF;
    END
    \$\$;
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${PGMASTER_USER};
    ALTER DATABASE ${POSTGRES_DB} OWNER TO ${PGMASTER_USER};
EOSQL

echo ">>> [init-master] habilitando extensiones base (plpython3u, postgres_fdw)"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS plpython3u;
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;
EOSQL

echo ">>> [init-master] listo."
