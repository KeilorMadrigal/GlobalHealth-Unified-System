#!/bin/bash
# Entrypoint propio de pg-replica (sustituye al entrypoint por defecto, ver
# docker-compose.yml: entrypoint del servicio pg-replica). No usa initdb: si
# PGDATA está vacío clona el maestro con pg_basebackup -R, que deja standby.signal
# y postgresql.auto.conf con primary_conninfo ya configurados -> al arrancar,
# PostgreSQL entra solo en modo standby. Copiar el volumen a mano NO sirve:
# pg_basebackup exige un PGDATA vacío y es lo único que deja el WAL y los
# metadatos de recovery consistentes.
set -euo pipefail

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
    echo ">>> [init-replica] PGDATA vacío. Esperando a que pg-master esté disponible..."
    until pg_isready -h "$PGMASTER_HOST" -p 5432 -U "$PG_REPLICATION_USER" >/dev/null 2>&1; do
        sleep 1
    done

    echo ">>> [init-replica] clonando maestro con pg_basebackup (slot=${PG_REPLICATION_SLOT})..."
    PGPASSWORD="$PG_REPLICATION_PASSWORD" pg_basebackup \
        -h "$PGMASTER_HOST" -p 5432 -U "$PG_REPLICATION_USER" \
        -D "$PGDATA" -Fp -Xs -P -R --slot="$PG_REPLICATION_SLOT"

    chmod 700 "$PGDATA"
    echo ">>> [init-replica] pg_basebackup completo. standby.signal presente: $(test -f "$PGDATA/standby.signal" && echo si || echo no)"
else
    echo ">>> [init-replica] PGDATA ya inicializado, se omite pg_basebackup."
fi

echo ">>> [init-replica] arrancando PostgreSQL en modo standby..."
exec docker-entrypoint.sh postgres
