#!/bin/bash
# Ver docker/shards/init-norte.sh: mismo patrón, para el nodo sur.
set -euo pipefail

echo ">>> [init-sur] creando rol de aplicación '${PGSUR_USER}'"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PGSUR_USER}') THEN
        CREATE ROLE ${PGSUR_USER} WITH LOGIN PASSWORD '${PGSUR_PASSWORD}';
      END IF;
    END
    \$\$;
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${PGSUR_USER};
    ALTER DATABASE ${POSTGRES_DB} OWNER TO ${PGSUR_USER};
EOSQL

echo ">>> [init-sur] listo."
