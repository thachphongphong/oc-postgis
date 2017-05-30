# Set default postgres admin user
PG_ADMIN_USER="postgres"
PSQL=/usr/pgsql-9.5/bin/psql
POSTGRESQL_ADMIN_PASSWORD=${POSTGRESQL_ADMIN_PASSWORD:-}

# Define the default postgres connection string
function set_connection_string () {
  PSQL="/usr/bin/psql postgresql://${PG_ADMIN_USER}:${POSTGRESQL_ADMIN_PASSWORD}@${PG_HOST}:5432/${POSTGRESQL_DATABASE}"
} 

# Database and schema management functions.
# We create a standard database in a RDS instance and schemas within that
# database per app.
function create_database () {
  echo "Creating database ${POSTGRESQL_DATABASE}"
  /usr/bin/psql postgresql://${PG_ADMIN_USER}:${POSTGRESQL_ADMIN_PASSWORD}@${PG_HOST}:5432/postgres \
    -c "CREATE DATABASE ${POSTGRESQL_DATABASE} WITH OWNER = ${PG_ADMIN_USER} ENCODING = 'UTF8' CONNECTION LIMIT = -1;"
  $PSQL -c "ALTER DATABASE ${POSTGRESQL_DATABASE} SET search_path TO \"\$user\",public,extensions;"
  $PSQL -c "GRANT ALL ON DATABASE ${POSTGRESQL_DATABASE} TO ${PG_ADMIN_USER};"
  $PSQL -c "REVOKE ALL ON DATABASE ${POSTGRESQL_DATABASE} FROM public;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO ${PG_ADMIN_USER};"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO ${PG_ADMIN_USER};"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO ${PG_ADMIN_USER};"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT USAGE ON TYPES TO ${PG_ADMIN_USER};"
  $PSQL -c "ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM public;" 
  $PSQL -c "ALTER DEFAULT PRIVILEGES REVOKE USAGE ON TYPES FROM public;"
}

function create_schema () {
  echo "Creating schema $SCHEMA"
  $PSQL -c "CREATE SCHEMA IF NOT EXISTS ${SCHEMA};"
}

function install_extensions () {
  echo "Installing extensions to the $SCHEMA schema"
  $PSQL -c "REVOKE ALL ON SCHEMA $SCHEMA FROM public;";
  $PSQL -c "GRANT USAGE ON SCHEMA $SCHEMA TO role_${POSTGRESQL_DATABASE}_ro;";
  $PSQL -c "GRANT USAGE ON SCHEMA $SCHEMA TO role_${POSTGRESQL_DATABASE}_rw;";
  $PSQL -c "GRANT ALL ON SCHEMA $SCHEMA TO postgres;";
  $PSQL -c "CREATE EXTENSION IF NOT EXISTS postgis;";
  $PSQL -c "GRANT USAGE ON SCHEMA $SCHEMA TO $POSTGRESQL_USER;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS sslinfo;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS hstore;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS uuid-ossp;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;";

}


# Role statements - we have rw and ro roles on databases and on schemas. We then create users and assign
# them to these roles. The following functions create the respective high level roles.
function create_ro_database_role () {
  echo "Creating read-only database role role_${POSTGRESQL_DATABASE}_ro"
  $PSQL -c "CREATE ROLE role_${POSTGRESQL_DATABASE}_ro NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "GRANT CONNECT, TEMPORARY ON DATABASE ${POSTGRESQL_DATABASE} TO role_${POSTGRESQL_DATABASE}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO role_${POSTGRESQL_DATABASE}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON SEQUENCES TO role_${POSTGRESQL_DATABASE}_ro;"
}

function create_rw_database_role () {
  echo "Creating read-write database role role_${POSTGRESQL_DATABASE}_rw"
  $PSQL -c "CREATE ROLE role_${POSTGRESQL_DATABASE}_rw NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;" 
  $PSQL -c "GRANT CONNECT, TEMPORARY ON DATABASE ${POSTGRESQL_DATABASE} TO role_${POSTGRESQL_DATABASE}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER ON TABLES TO role_${POSTGRESQL_DATABASE}_rw;" 
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO role_${POSTGRESQL_DATABASE}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO role_${POSTGRESQL_DATABASE}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT USAGE ON TYPES TO role_${POSTGRESQL_DATABASE}_rw;"
}

function create_ro_schema_role () {
  echo "Creating read-only role role_${SCHEMA}_ro for schema ${SCHEMA}"
  $PSQL -c "CREATE ROLE role_${SCHEMA}_ro NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "GRANT CONNECT on DATABASE ${POSTGRESQL_DATABASE} TO role_${SCHEMA}_ro;"
  $PSQL -c "GRANT USAGE ON SCHEMA ${SCHEMA} TO role_${SCHEMA}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO role_${SCHEMA}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON SEQUENCES TO role_${SCHEMA}_ro;"
}

function create_rw_schema_role () {
  echo "Creating read-write role role_${SCHEMA}_rw for schema ${SCHEMA}"
  $PSQL -c "CREATE ROLE role_${SCHEMA}_rw NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "GRANT CONNECT on DATABASE ${POSTGRESQL_DATABASE} TO role_${SCHEMA}_rw;"
  $PSQL -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ${SCHEMA} TO role_${SCHEMA}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO role_${SCHEMA}_rw;"
  $PSQL -c "GRANT CREATE ON SCHEMA ${SCHEMA} TO role_${SCHEMA}_rw;" 
  $PSQL -c "GRANT USAGE ON SCHEMA ${SCHEMA} TO role_${SCHEMA}_rw;" 
}

function create_user() {
  echo "Creating user $POSTGRESQL_USER"
  $PSQL -c "CREATE ROLE ${POSTGRESQL_USER} LOGIN NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "ALTER ROLE ${POSTGRESQL_USER} WITH PASSWORD '${USER_PASSWORD}';"
}

function grant_role_to_user() {
  echo "Granting role $ROLE to user $POSTGRESQL_USER"
  $PSQL -c "GRANT $ROLE TO ${POSTGRESQL_USER};"
}

  
# Database status functions - things like determining which schemas and users are in place
function list_databases() {
  echo "Listing databases on rds instance $PG_HOST"
  $PSQL -l
}

function list_schemas() {
  echo "Listing schemas on database $POSTGRESQL_DATABASE"
  $PSQL -c "SELECT nspname from pg_catalog.pg_namespace;"
}

function list_users() {
  echo "Listing user definitions on rds instance $PG_HOST"
  $PSQL -c '\du'
}