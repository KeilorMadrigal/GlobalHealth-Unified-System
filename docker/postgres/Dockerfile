# Imagen base para TODOS los nodos PostgreSQL del proyecto (master, réplica,
# pg-norte, pg-sur). Se construye una imagen propia -en vez de usar bitnami u
# otra imagen de terceros- porque la Fase 3 necesita PL/Python3u + lxml para
# validar XML contra XSD dentro del motor, y esas extensiones no vienen en la
# imagen oficial postgres:16.
FROM postgres:16

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-plpython3-16 \
        python3-lxml \
    && rm -rf /var/lib/apt/lists/*

# postgres_fdw viene incluido en contrib de la imagen oficial (no requiere
# paquete adicional); se habilita con CREATE EXTENSION en el SQL de la Fase 5.
