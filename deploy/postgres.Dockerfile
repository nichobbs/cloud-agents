# Postgres for cloud-agents (docs/phase11-postgres-tenancy.md §8). The stock
# image plus a first-start init script that runs deploy/postgres/provision.sql
# with the role passwords from the environment.
FROM postgres:16.10-alpine
COPY deploy/postgres/provision.sql /opt/cloud-agents/provision.sql
COPY deploy/postgres/init.sh /docker-entrypoint-initdb.d/10-cloud-agents.sh
COPY deploy/postgres/entrypoint.sh /usr/local/bin/cloud-agents-entrypoint.sh
RUN chmod 0644 /opt/cloud-agents/provision.sql \
    && chmod 0755 /docker-entrypoint-initdb.d/10-cloud-agents.sh /usr/local/bin/cloud-agents-entrypoint.sh
# Setting ENTRYPOINT clears the base image's CMD, so it is restated.
ENTRYPOINT ["cloud-agents-entrypoint.sh"]
CMD ["postgres"]
