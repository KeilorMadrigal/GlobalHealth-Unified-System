#!/bin/bash
# Inicialización mínima de pg-norte: solo crea el rol de aplicación. Las
# tablas físicas (pacientes_norte, paciente_publico, paciente_financiero)
# se crean explícitamente desde sql/07_frag_horizontal.sql y
# sql/08_frag_vertical.sql para que queden visibles y explicables en la
# defensa, no escondidas en un script de arranque.
set -euo pipefail

echo ">>> [init-norte] creando rol de aplicación '${PGNORTE_USER}'"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PGNORTE_USER}') THEN
        CREATE ROLE ${PGNORTE_USER} WITH LOGIN PASSWORD '${PGNORTE_PASSWORD}';
      END IF;
    END
    \$\$;
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${PGNORTE_USER};
    ALTER DATABASE ${POSTGRES_DB} OWNER TO ${PGNORTE_USER};
EOSQL

echo ">>> [init-norte] listo."
