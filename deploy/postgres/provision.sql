-- One-time role and database provisioning for cloud-agents on Postgres
-- (docs/phase11-postgres-tenancy.md §5.1, §8). Run ONCE as a superuser:
--
--   psql -v ON_ERROR_STOP=1 \
--        -v owner_password="'...'" -v app_password="'...'" \
--        -v migrator_password="'...'" \
--        -f deploy/postgres/provision.sql
--
-- (Each password variable is passed already single-quoted, as shown.) The
-- compose files' postgres service runs it on first start through
-- deploy/postgres/init.sh. The superuser's own credentials never go into the
-- API's environment.
--
-- Everything else (tables, RLS policies, claim functions, per-table grants)
-- is created by the service's migrations (`--migrate`), which run as
-- cloudagents_owner and stay versioned with the schema.
--
-- Roles:
--   cloudagents_owner    LOGIN. Owns every schema object; used only by --migrate.
--   cloudagents_app      LOGIN. The service role: not owner, not superuser,
--                        no BYPASSRLS, so FORCE ROW LEVEL SECURITY applies.
--   cloudagents_claimer  NOLOGIN. Owns only the SECURITY DEFINER claim
--                        functions; reachable only through them.
--   cloudagents_migrator NOLOGIN + BYPASSRLS. Was for the one-shot SQLite
--                        export, which is dropped (phase 11 spec §7); unused,
--                        and removed at the cut-over (slice E).

\set ON_ERROR_STOP on

CREATE ROLE cloudagents_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS
    PASSWORD :owner_password;
CREATE ROLE cloudagents_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS
    PASSWORD :app_password;
CREATE ROLE cloudagents_claimer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE ROLE cloudagents_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE BYPASSRLS
    PASSWORD :migrator_password;

-- The owner must be able to make the claimer own the claim functions
-- (ALTER FUNCTION ... OWNER TO needs SET on the target role) without
-- inheriting the claimer's table policies. INHERIT FALSE keeps the owner
-- itself subject to FORCE ROW LEVEL SECURITY like everyone else.
GRANT cloudagents_claimer TO cloudagents_owner WITH INHERIT FALSE, SET TRUE;

CREATE DATABASE cloudagents OWNER cloudagents_owner;
REVOKE ALL ON DATABASE cloudagents FROM PUBLIC;
GRANT CONNECT ON DATABASE cloudagents TO cloudagents_app, cloudagents_migrator;

\connect cloudagents

REVOKE ALL ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO cloudagents_owner;
GRANT USAGE ON SCHEMA public TO cloudagents_app, cloudagents_claimer, cloudagents_migrator;
