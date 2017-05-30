# Set default postgres admin user
PG_ADMIN_USER="postgres"
PSQL=/usr/pgsql-9.5/bin/psql
PG_ADMIN_PASSWORD=${POSTGRESQL_ADMIN_PASSWORD:-}
USER=${POSTGRESQL_USER}
DB_NAME=${POSTGRESQL_DATABASE}

# Define the default postgres connection string
function set_connection_string () {
  PSQL="/usr/bin/psql postgresql://${PG_ADMIN_USER}:${PG_ADMIN_PASSWORD}@${PG_HOST}:5432/${DB_NAME}"
} 

# Database and schema management functions.
# We create a standard database in a RDS instance and schemas within that
# database per app.
function create_database () {
  echo "Creating database ${DB_NAME}"
  /usr/bin/psql postgresql://${PG_ADMIN_USER}:${PG_ADMIN_PASSWORD}@${PG_HOST}:5432/postgres \
    -c "CREATE DATABASE ${DB_NAME} WITH OWNER = ${PG_ADMIN_USER} ENCODING = 'UTF8' CONNECTION LIMIT = -1;"
  $PSQL -c "ALTER DATABASE ${DB_NAME} SET search_path TO \"\$user\",public,extensions;"
  $PSQL -c "GRANT ALL ON DATABASE ${DB_NAME} TO ${PG_ADMIN_USER};"
  $PSQL -c "REVOKE ALL ON DATABASE ${DB_NAME} FROM public;"
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
  $PSQL -c "GRANT USAGE ON SCHEMA $SCHEMA TO role_${DB_NAME}_ro;";
  $PSQL -c "GRANT USAGE ON SCHEMA $SCHEMA TO role_${DB_NAME}_rw;";
  $PSQL -c "GRANT ALL ON SCHEMA $SCHEMA TO postgres;";
  $PSQL -c "CREATE EXTENSION IF NOT EXISTS postgis;";
  $PSQL -c "GRANT USAGE ON SCHEMA $SCHEMA TO $USER;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS sslinfo;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS hstore;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS uuid-ossp;";
#  $PSQL -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;";

}


# Role statements - we have rw and ro roles on databases and on schemas. We then create users and assign
# them to these roles. The following functions create the respective high level roles.
function create_ro_database_role () {
  echo "Creating read-only database role role_${DB_NAME}_ro"
  $PSQL -c "CREATE ROLE role_${DB_NAME}_ro NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "GRANT CONNECT, TEMPORARY ON DATABASE ${DB_NAME} TO role_${DB_NAME}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO role_${DB_NAME}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON SEQUENCES TO role_${DB_NAME}_ro;"
}

function create_rw_database_role () {
  echo "Creating read-write database role role_${DB_NAME}_rw"
  $PSQL -c "CREATE ROLE role_${DB_NAME}_rw NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;" 
  $PSQL -c "GRANT CONNECT, TEMPORARY ON DATABASE ${DB_NAME} TO role_${DB_NAME}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER ON TABLES TO role_${DB_NAME}_rw;" 
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO role_${DB_NAME}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO role_${DB_NAME}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT USAGE ON TYPES TO role_${DB_NAME}_rw;"
}

function create_ro_schema_role () {
  echo "Creating read-only role role_${SCHEMA}_ro for schema ${SCHEMA}"
  $PSQL -c "CREATE ROLE role_${SCHEMA}_ro NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "GRANT CONNECT on DATABASE ${DB_NAME} TO role_${SCHEMA}_ro;"
  $PSQL -c "GRANT USAGE ON SCHEMA ${SCHEMA} TO role_${SCHEMA}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO role_${SCHEMA}_ro;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT SELECT ON SEQUENCES TO role_${SCHEMA}_ro;"
}

function create_rw_schema_role () {
  echo "Creating read-write role role_${SCHEMA}_rw for schema ${SCHEMA}"
  $PSQL -c "CREATE ROLE role_${SCHEMA}_rw NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "GRANT CONNECT on DATABASE ${DB_NAME} TO role_${SCHEMA}_rw;"
  $PSQL -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ${SCHEMA} TO role_${SCHEMA}_rw;"
  $PSQL -c "ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO role_${SCHEMA}_rw;"
  $PSQL -c "GRANT CREATE ON SCHEMA ${SCHEMA} TO role_${SCHEMA}_rw;" 
  $PSQL -c "GRANT USAGE ON SCHEMA ${SCHEMA} TO role_${SCHEMA}_rw;" 
}

function create_user() {
  echo "Creating user $USER"
  $PSQL -c "CREATE ROLE ${USER} LOGIN NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;"
  $PSQL -c "ALTER ROLE ${USER} WITH PASSWORD '${USER_PASSWORD}';"
}

function grant_role_to_user() {
  echo "Granting role $ROLE to user $USER"
  $PSQL -c "GRANT $ROLE TO ${USER};"
}

# Drop functions - simple functions to help clean up
function drop_database() {
  echo "Dropping database $DB_NAME on rds instance $PG_HOST"
  /usr/bin/psql postgresql://${PG_ADMIN_USER}:${PG_ADMIN_PASSWORD}@${PG_HOST}:5432/postgres \
    -c "SELECT pg_terminate_backend(pid) from pg_stat_activity where datname='${DB_NAME}';"
  /usr/bin/psql postgresql://${PG_ADMIN_USER}:${PG_ADMIN_PASSWORD}@${PG_HOST}:5432/postgres \
    -c "DROP DATABASE ${DB_NAME}"
}

function drop_role() {
  echo "Dropping role $ROLE on rds instance $PG_HOST"
  $PSQL -c "DROP ROLE ${ROLE}"
}
function drop_schema() {
  echo "Dropping schema $SCHEMA from database $DB_NAME on rds instance $PG_HOST"
  $PSQL -c "DROP SCHEMA ${SCHEMA}"
}
  
# Database status functions - things like determining which schemas and users are in place
function list_databases() {
  echo "Listing databases on rds instance $PG_HOST"
  $PSQL -l
}
function list_schemas() {
  echo "Listing schemas on database $DB_NAME"
  $PSQL -c "SELECT nspname from pg_catalog.pg_namespace;"
}
function list_users() {
  echo "Listing user definitions on rds instance $PG_HOST"
  $PSQL -c '\du'
}

# The following functions will be expanded to not only check variables but
# also do preliminary checks on the database in question
function check_opt_db() {
  if [ -z $DB_NAME ] ; then
    echo "DB Name not set - exiting"
    exit 1
  fi
}
function check_opt_schema() {
  if [ -z $SCHEMA ] ; then
    echo "Schema name not set - exiting"
    exit 1
  fi
}
function check_opt_user() {
  if [ -z $USER ] ; then
    echo "User name not set - exiting"
    exit 1
  fi
}
function check_opt_role() {
  if [ -z $ROLE ] ; then
    echo "Role name not set - exiting"
    exit 1
  fi
}