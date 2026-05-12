#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

log() {
    if [[ "${1:-}" == ERROR ]]; then
        echo "[ERROR] ${*:2}" >&2
    else
        echo "[INFO]  $*"
    fi
}

log "Starting Pulp Project deployment prep ..."

if [[ -z "${USERS_YAML:-}" ]]; then
    log ERROR "USERS_YAML must be set to the path of your Pulp users YAML (repository file configs/users.yaml)."
    log ERROR "Example: export USERS_YAML=/path/to/pulp-project/configs/users.yaml"
    exit 1
fi

load_config_from_yaml() {
    local f="$1"
    if ! command -v yq >/dev/null 2>&1; then
        log ERROR "yq is required to read ${f}."
        exit 1
    fi
    if [[ ! -f "$f" ]]; then
        log ERROR "Config file not found: ${f}"
        log ERROR "Check USERS_YAML points at a valid file."
        exit 1
    fi

    # Set all values from the config file
    PULP_DEFAULT_ADMIN_USERNAME=$(yq -r '.default.username' "$f")
    PULP_DEFAULT_ADMIN_PASSWORD=$(yq -r '.default.password' "$f")
    PULP_ADMIN_USERNAME=$(yq -r '.admin.username' "$f")
    PULP_ADMIN_PASSWORD=$(yq -r '.admin.password' "$f")
    PULP_PUBLISHER_USERNAME=$(yq -r '.publisher.username' "$f")
    PULP_PUBLISHER_PASSWORD=$(yq -r '.publisher.password' "$f")
    PULP_VIEWER_USERNAME=$(yq -r '.viewer.username' "$f")
    PULP_VIEWER_PASSWORD=$(yq -r '.viewer.password' "$f")
    PULP_DB_NAME=$(yq -r '.db.dbname' "$f")
    PULP_DB_USER=$(yq -r '.db.username' "$f")
    PULP_DB_PASSWORD=$(yq -r '.db.password' "$f")

    local v
    for v in PULP_DEFAULT_ADMIN_USERNAME PULP_DEFAULT_ADMIN_PASSWORD \
              PULP_ADMIN_USERNAME PULP_ADMIN_PASSWORD \
              PULP_PUBLISHER_USERNAME PULP_PUBLISHER_PASSWORD \
              PULP_VIEWER_USERNAME PULP_VIEWER_PASSWORD \
              PULP_DB_NAME PULP_DB_USER PULP_DB_PASSWORD; do
        if [[ -z "${!v:-}" || "${!v}" == "null" ]]; then
            log ERROR "${v} is empty or null; check ${f}."
            exit 1
        fi
    done

    export PULP_DEFAULT_ADMIN_USERNAME PULP_DEFAULT_ADMIN_PASSWORD \
           PULP_ADMIN_USERNAME PULP_ADMIN_PASSWORD \
           PULP_PUBLISHER_USERNAME PULP_PUBLISHER_PASSWORD \
           PULP_VIEWER_USERNAME PULP_VIEWER_PASSWORD \
           PULP_DB_NAME PULP_DB_USER PULP_DB_PASSWORD
}

load_config_from_yaml "${USERS_YAML}"

# Set PULP_API_URL using host IP
PULP_SERVER_IP=$(hostname -I | awk '{print $1}')
export PULP_SERVER_IP
export PULP_API_URL="http://${PULP_SERVER_IP}:24817"
export PULP_SERVER_URL="http://${PULP_SERVER_IP}:8080"

# Set default pulp directory if not provided
PULP_BASE_DIR="./pulp-data"
if [ -n "${1:-}" ]; then
    log "Using user provided PULP_BASE_DIR=$1"
    PULP_BASE_DIR=${1}
fi

# Set and export pulp directory for dir-type volumes
export PULP_BASE_DIR="$(realpath "$PULP_BASE_DIR")"
log "Using PULP_BASE_DIR=$PULP_BASE_DIR"

# Create required directories for pulp data
log "Create directory-type volume dirs in $PULP_BASE_DIR for podman compose ..."
mkdir -p "${PULP_BASE_DIR}"/{pgsql,pulp_storage,settings,redis_data,nginx_conf}

# Copy nginx.conf to the deployment directory
log "Copy nginx.conf to $PULP_BASE_DIR ..."
cp config/nginx.conf "${PULP_BASE_DIR}/nginx_conf/nginx.conf"

# Generate SSL certificate and key
log "Generating SSL certificate and key in $PULP_BASE_DIR/settings/certs ..."
mkdir -p ${PULP_BASE_DIR}/settings/certs
openssl rand -base64 32 > ${PULP_BASE_DIR}/settings/certs/database_fields.symmetric.key
openssl genrsa -out ${PULP_BASE_DIR}/settings/certs/container_auth_private_key.pem 4096
openssl rsa -in ${PULP_BASE_DIR}/settings/certs/container_auth_private_key.pem \
            -pubout -out ${PULP_BASE_DIR}/settings/certs/container_auth_public_key.pem

# Set execute permissions for base directory
podman unshare chmod -R 755 ${PULP_BASE_DIR}

# Enable linger for the current user
log "Enabling linger for the current user ..."
loginctl enable-linger $(id -u)

# Deploy pulp project using podman compose
log "Deploy pulp project using podman compose ..."
podman-compose -f ./podman-compose.yaml up -d

# Validate pulp_api status for up to ~30 minutes, checking every 20 seconds
log "Validating pulp_api status (max 30 minutes, interval 20s) ..."
max_attempts=91
interval=20
attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
    if curl -sf -o /dev/null --connect-timeout 5 "${PULP_API_URL}/pulp/api/v3/status/" 2>/dev/null; then
        log "pulp_api is ready (attempt $attempt)."
        break
    fi

    if [ "$attempt" -eq "$max_attempts" ]; then
        log ERROR "pulp_api did not become ready within 30 minutes."
        exit 1
    fi
    log "  Attempt $attempt/$max_attempts: pulp_api not ready, retrying in ${interval}s ..."
    sleep "$interval"
    attempt="$((attempt + 1))"
done

# Get pulp_api container ID
pulp_api_container=$(podman ps -q --filter name=pulp_api)
if [[ -z "${pulp_api_container}" ]]; then
    log ERROR "pulp_api container not found. Is podman-compose running?"
    exit 1
fi

# Reset the built-in admin password
log "Setting default admin (${PULP_DEFAULT_ADMIN_USERNAME}) password ..."
podman exec -i ${pulp_api_container} pulpcore-manager reset-admin-password --password "${PULP_DEFAULT_ADMIN_PASSWORD}"

# Helper: create a Pulp user via the API
create_pulp_user() {
    local username="$1"
    local password="$2"
    local is_superuser="${3:-false}"

    log "Creating Pulp user: ${username} (superuser=${is_superuser}) ..."
    local resp
    resp=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${PULP_DEFAULT_ADMIN_USERNAME}:${PULP_DEFAULT_ADMIN_PASSWORD}" \
        -X POST "${PULP_SERVER_URL}/pulp/api/v3/users/" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"${username}\", \"password\": \"${password}\", \"is_superuser\": ${is_superuser}}")
    if [[ ! "${resp}" =~ ^2[0-9][0-9]$ ]]; then
        log ERROR "Could not create user ${username} (HTTP ${resp})."
        exit 1
    fi
}

# Create admin, publisher, and viewer users.
# cephadmin uses is_superuser=false; its permissions are assigned via --set-admin-permissions.
create_pulp_user "${PULP_ADMIN_USERNAME}"     "${PULP_ADMIN_PASSWORD}"     false
create_pulp_user "${PULP_PUBLISHER_USERNAME}" "${PULP_PUBLISHER_PASSWORD}" false
create_pulp_user "${PULP_VIEWER_USERNAME}"    "${PULP_VIEWER_PASSWORD}"    false

log "pulp_api is ready at ${PULP_API_URL}."
log "Access Pulp API docs at ${PULP_API_URL}/pulp/api/v3/docs/"
