PG_HOST=${PG_HOST:-localhost}
PG_ADMIN_USER="postgres"

# Configuration settings.
export POSTGRESQL_MAX_CONNECTIONS=${POSTGRESQL_MAX_CONNECTIONS:-100}
export POSTGRESQL_MAX_PREPARED_TRANSACTIONS=${POSTGRESQL_MAX_PREPARED_TRANSACTIONS:-0}

# Perform auto-tuning based on the container cgroups limits (only when the
# limits are set).
# Users can still override this by setting the POSTGRESQL_SHARED_BUFFERS
# and POSTGRESQL_EFFECTIVE_CACHE_SIZE variables.
if [[ "${NO_MEMORY_LIMIT:-}" == "true" || -z "${MEMORY_LIMIT_IN_BYTES:-}" ]]; then
    export POSTGRESQL_SHARED_BUFFERS=${POSTGRESQL_SHARED_BUFFERS:-32MB}
    export POSTGRESQL_EFFECTIVE_CACHE_SIZE=${POSTGRESQL_EFFECTIVE_CACHE_SIZE:-128MB}
else
    # Use 1/4 of given memory for shared buffers
    shared_buffers_computed="$(($MEMORY_LIMIT_IN_BYTES/1024/1024/4))MB"
    # Setting effective_cache_size to 1/2 of total memory would be a normal conservative setting,
    effective_cache="$(($MEMORY_LIMIT_IN_BYTES/1024/1024/2))MB"
    export POSTGRESQL_SHARED_BUFFERS=${POSTGRESQL_SHARED_BUFFERS:-$shared_buffers_computed}
    export POSTGRESQL_EFFECTIVE_CACHE_SIZE=${POSTGRESQL_EFFECTIVE_CACHE_SIZE:-$effective_cache}
fi

export POSTGRESQL_RECOVERY_FILE=$HOME/openshift-custom-recovery.conf
export POSTGRESQL_CONFIG_FILE=$HOME/openshift-custom-postgresql.conf

postinitdb_actions=

psql_identifier_regex='^[a-zA-Z_][a-zA-Z0-9_]*$'
psql_password_regex='^[a-zA-Z0-9_~!@#$%^&*()-=<>,.?;:|]+$'

# match . files when moving userdata below
shopt -s dotglob
# extglob enables the !(userdata) glob pattern below.
shopt -s extglob

function usage() {
  if [ $# == 1 ]; then
    echo >&2 "error: $1"
  fi

  cat >&2 <<EOF
You must either specify the following environment variables:
  POSTGRESQL_USER (regex: '$psql_identifier_regex')
  POSTGRESQL_PASSWORD (regex: '$psql_password_regex')
  POSTGRESQL_DATABASE (regex: '$psql_identifier_regex')
Or the following environment variable:
  POSTGRESQL_ADMIN_PASSWORD (regex: '$psql_password_regex')
Or both.
Optional settings:
  POSTGRESQL_MAX_CONNECTIONS (default: 100)
  POSTGRESQL_MAX_PREPARED_TRANSACTIONS (default: 0)
  POSTGRESQL_SHARED_BUFFERS (default: 32MB)

For more information see /usr/share/container-scripts/postgresql/README.md
within the container or visit https://github.com/openshift/postgresql.
EOF
  exit 1
}

function check_env_vars() {
  echo "Check env vars User ${POSTGRESQL_USER} Pass $POSTGRESQL_PASSWORD Db $POSTGRESQL_DATABASE Mpass $POSTGRESQL_ADMIN_PASSWORD"

  if [[ -v POSTGRESQL_USER || -v POSTGRESQL_PASSWORD || -v POSTGRESQL_DATABASE ]]; then
    # one var means all three must be specified
    [[ -v POSTGRESQL_USER && -v POSTGRESQL_PASSWORD && -v POSTGRESQL_DATABASE ]] || usage
    [[ "$POSTGRESQL_USER"     =~ $psql_identifier_regex ]] || usage
    [[ "$POSTGRESQL_PASSWORD" =~ $psql_password_regex   ]] || usage
    [[ "$POSTGRESQL_DATABASE" =~ $psql_identifier_regex ]] || usage
    [ ${#POSTGRESQL_USER}     -le 63 ] || usage "PostgreSQL username too long (maximum 63 characters)"
    [ ${#POSTGRESQL_DATABASE} -le 63 ] || usage "Database name too long (maximum 63 characters)"
    postinitdb_actions+=",simple_db"
  fi

  if [ -v POSTGRESQL_ADMIN_PASSWORD ]; then
    [[ "$POSTGRESQL_ADMIN_PASSWORD" =~ $psql_password_regex ]] || usage
    postinitdb_actions+=",admin_pass"
  fi

  case ",$postinitdb_actions," in
    *,admin_pass,*|*,simple_db,*) ;;
    *) usage ;;
  esac

}

# Make sure env variables don't propagate to PostgreSQL process.
function unset_env_vars() {
  unset POSTGRESQL_{DATABASE,USER,PASSWORD,ADMIN_PASSWORD}
}

# postgresql_master_addr lookups the 'postgresql-master' DNS and get list of the available
# endpoints. Each endpoint is a PostgreSQL container with the 'master' PostgreSQL running.
function postgresql_master_addr() {
  local service_name=${POSTGRESQL_MASTER_SERVICE_NAME:-postgresql-master}
  local endpoints=$(dig ${service_name} A +search | grep ";${service_name}" | cut -d ';' -f 2 2>/dev/null)
  # FIXME: This is for debugging (docker run)
  if [ -v POSTGRESQL_MASTER_IP ]; then
    endpoints=${POSTGRESQL_MASTER_IP:-}
  fi
  if [ -z "$endpoints" ]; then
    >&2 echo "Failed to resolve PostgreSQL master IP address"
    exit 3
  fi
  echo -n "$(echo $endpoints | cut -d ' ' -f 1)"
}

# New config is generated every time a container is created. It only contains
# additional custom settings and is included from $PGDATA/postgresql.conf.
function generate_postgresql_config() {
  envsubst \
      < "${CONTAINER_SCRIPTS_PATH}/openshift-custom-postgresql.conf.template" \
      > "${POSTGRESQL_CONFIG_FILE}"

  if [ "${ENABLE_REPLICATION}" == "true" ]; then
    envsubst \
        < "${CONTAINER_SCRIPTS_PATH}/openshift-custom-postgresql-replication.conf.template" \
        >> "${POSTGRESQL_CONFIG_FILE}"
  fi
}

function generate_postgresql_recovery_config() {
  envsubst \
      < "${CONTAINER_SCRIPTS_PATH}/openshift-custom-recovery.conf.template" \
      > "${POSTGRESQL_RECOVERY_FILE}"
}

# Generate passwd file based on current uid
function generate_passwd_file() {
  export USER_ID=$(id -u)
  export GROUP_ID=$(id -g)
  grep -v ^postgres /etc/passwd > "$HOME/passwd"
  echo "postgres:x:${USER_ID}:${GROUP_ID}:PostgreSQL Server:${HOME}:/bin/bash" >> "$HOME/passwd"
  export LD_PRELOAD=libnss_wrapper.so
  export NSS_WRAPPER_PASSWD=${HOME}/passwd
  export NSS_WRAPPER_GROUP=/etc/group
}

function initialize_database() {
  # Initialize the database cluster with utf8 support enabled by default.
  # This might affect performance, see:
  # http://www.postgresql.org/docs/9.5/static/locale.html
  LANG=${LANG:-en_US.utf8} initdb

  # PostgreSQL configuration.
  cat >> "$PGDATA/postgresql.conf" <<EOF

# Custom OpenShift configuration:
include '${POSTGRESQL_CONFIG_FILE}'
EOF

  # Access control configuration.
  # FIXME: would be nice-to-have if we could allow connections only from
  #        specific hosts / subnet
  cat >> "$PGDATA/pg_hba.conf" <<EOF

#
# Custom OpenShift configuration starting at this point.
#

# Allow connections from all hosts.
host all all all md5

# Allow replication connections from all hosts.
host replication all all md5
EOF
}

function create_users() {
  if [[ ",$postinitdb_actions," = *,simple_db,* ]]; then
    echo "Creating user ${POSTGRESQL_USER} DB $POSTGRESQL_DATABASE"
    createuser "$POSTGRESQL_USER"
#    createdb --owner="$POSTGRESQL_USER" "$POSTGRESQL_DATABASE"
  fi

  if [ -v POSTGRESQL_MASTER_USER ]; then
    echo "Creating user ${POSTGRESQL_MASTER_USER}"
    createuser "$POSTGRESQL_MASTER_USER"
  fi
}

function set_passwords() {
  echo "Setting password"
  if [[ ",$postinitdb_actions," = *,simple_db,* ]]; then
    psql --command "ALTER USER \"${POSTGRESQL_USER}\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_PASSWORD}';"
  fi

  if [ -v POSTGRESQL_MASTER_USER ]; then
    psql --command "ALTER USER \"${POSTGRESQL_MASTER_USER}\" WITH REPLICATION;"
    psql --command "ALTER USER \"${POSTGRESQL_MASTER_USER}\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_MASTER_PASSWORD}';"
  fi

  if [ -v POSTGRESQL_ADMIN_PASSWORD ]; then
    psql --command "ALTER USER \"postgres\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_ADMIN_PASSWORD}';"
  fi
}

function set_pgdata ()
{
  # backwards compatibility case, we used to put the data here,
  # move it into our new expected location (userdata)
  if [ -e ${HOME}/data/PG_VERSION ]; then
    mkdir -p "${HOME}/data/userdata"
    pushd "${HOME}/data"
    # move everything except the userdata directory itself, into the userdata directory.
    mv !(userdata) "userdata"
    popd
  else 
    # create a subdirectory that the user owns
    mkdir -p "${HOME}/data/userdata"
  fi
  export PGDATA=$HOME/data/userdata
  # ensure sane perms for postgresql startup
  chmod 700 "$PGDATA"
}

function wait_for_postgresql_master() {
  while true; do
    echo "Waiting for PostgreSQL master (${PSQL}) to accept connections ..."
    $PSQL -c "SELECT 1;" && return 0
    sleep 1
  done
}

# Define the default postgres connection string
function set_connection_string () {
  PSQL="psql postgresql://${PG_ADMIN_USER}:${POSTGRESQL_ADMIN_PASSWORD}@${PG_HOST}:5432/${POSTGRESQL_DATABASE}"
} 

# Database and schema management functions.
# We create a standard database in a RDS instance and schemas within that
# database per app.
function create_database () {
  echo "Creating database ${POSTGRESQL_DATABASE}"
  psql "postgresql://${PG_ADMIN_USER}:${POSTGRESQL_ADMIN_PASSWORD}@${PG_HOST}:5432/postgres" \
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
#  psql -c "CREATE EXTENSION IF NOT EXISTS sslinfo;";
#  psql -c "CREATE EXTENSION IF NOT EXISTS hstore;";
#  psql -c "CREATE EXTENSION IF NOT EXISTS uuid-ossp;";
#  psql -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;";

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