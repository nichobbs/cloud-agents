# Postgres for cloud-agents (docs/phase11-postgres-tenancy.md §8). The stock
# image plus a first-start init script that runs deploy/postgres/provision.sql
# with the role passwords from the environment.
FROM postgres:16.10-alpine
COPY deploy/postgres/provision.sql /opt/cloud-agents/provision.sql
COPY deploy/postgres/init.sh /docker-entrypoint-initdb.d/10-cloud-agents.sh
RUN chmod 0644 /opt/cloud-agents/provision.sql \
    && chmod 0755 /docker-entrypoint-initdb.d/10-cloud-agents.sh
