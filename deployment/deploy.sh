#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -euxo pipefail

echo "Starting Pulp Project deployment prep ..."

# Set database password
export PULP_DB_NAME=${PULP_DB_NAME:-"pulpdb"}
export PULP_DB_USER=${PULP_DB_USER:-"pulp"}
export PULP_DB_PASSWORD=${PULP_DB_PASSWORD:-"pulp123"}

# Set pulp user details
export PULP_ADMIN_PASSWORD=${PULP_ADMIN_PASSWORD:-"pulp123"}
export PULP_USERNAME=${PULP_USERNAME:-"cephuser"}
export PULP_PASSWORD=${PULP_PASSWORD:-"cephuser123"}

# Set pulp user permissions
ROLES=(
    "rpm.rpmrepository_creator"
    "rpm.rpmremote_creator"
    "rpm.rpmdistribution_creator"
    "deb.aptrepository_creator"
    "deb.aptremote_creator"
    "deb.aptdistribution_creator"
    "core.upload_creator"
)

# Set PULP_API_URL using host IP (fallback to localhost)
PULP_IP=$(hostname -I | awk '{print $1}')
export PULP_API_URL="http://${PULP_IP}:24817"
export PULP_SERVER_URL="http://${PULP_IP}:8080"

# Set default pulp directory if not provided
PULP_BASE_DIR="./pulp-data"
if [ -n "${1:-}" ]; then
    echo "Using user provided PULP_BASE_DIR=$1"
    PULP_BASE_DIR=${1}
fi

# Set and export pulp directory for dir-type volumes
export PULP_BASE_DIR="$(realpath "$PULP_BASE_DIR")"
echo "Using PULP_BASE_DIR=$PULP_BASE_DIR"

# Create required directories for pulp data
echo "Create directory-type volume dirs in $PULP_BASE_DIR for podman compose ..."
mkdir -p "${PULP_BASE_DIR}"/{pgsql,pulp_storage,settings,redis_data,nginx_conf}

# Copy nginx.conf to the deployment directory
echo "Copy nginx.conf to $PULP_BASE_DIR ..."
cp config/nginx.conf "${PULP_BASE_DIR}/nginx_conf/nginx.conf"

# Generate SSL certificate and key
mkdir -p ${PULP_BASE_DIR}/settings/certs
openssl rand -base64 32 > ${PULP_BASE_DIR}/settings/certs/database_fields.symmetric.key

# Set execute permissions for base directory
podman unshare chmod -R 755 ${PULP_BASE_DIR}

# Enable linger for the current user
echo "Enabling linger for the current user ..."
loginctl enable-linger $(id -u)

# Deploy pulp project using podman compose
echo "Deploy pulp project using podman compose ..."
podman-compose -f ./podman-compose.yaml up -d

# Validate pulp_api status for up to 10 minutes, checking every 20 seconds
echo "Validating pulp_api status (max 30 minutes, interval 20s) ..."
max_attempts=91
interval=20
attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
    if curl -sf -o /dev/null --connect-timeout 5 "${PULP_API_URL}/pulp/api/v3/status/" 2>/dev/null; then
        echo "pulp_api is ready (attempt $attempt)."
        break
    fi

    if [ "$attempt" -eq "$max_attempts" ]; then
        echo "Error: pulp_api did not become ready within 10 minutes."
        exit 1
    fi
    echo "  Attempt $attempt/$max_attempts: pulp_api not ready, retrying in ${interval}s ..."
    sleep "$interval"
    attempt="$((attempt + 1))"
done

# Get pulp_api container ID
pulp_api_container=$(podman ps -q --filter name=pulp_api)

# Set pulp admin password
echo "Setting pulp admin password to $PULP_ADMIN_PASSWORD ..."
podman exec -it ${pulp_api_container} pulpcore-manager reset-admin-password --password "${PULP_ADMIN_PASSWORD}"

# Create pulp user
echo "Creating pulp user $PULP_USERNAME with password $PULP_PASSWORD ..."
response=$(curl -s -o /dev/null -w "%{http_code}\n" -u admin:${PULP_ADMIN_PASSWORD} \
         -X POST ${PULP_SERVER_URL}/pulp/api/v3/users/ \
         -H "Content-Type: application/json" \
         -d "{\"username\": \"${PULP_USERNAME}\", \"password\": \"${PULP_PASSWORD}\"}")

# Validate response
if [ "$response" == "null" ] || [ -z "$response" ]; then
    echo "Error: Could not create user $PULP_USERNAME"
    exit 1
fi

# Get href of the new user
USER_HREF=$(curl -s -u admin:${PULP_ADMIN_PASSWORD} \
    ${PULP_SERVER_URL}/pulp/api/v3/users/?username=${PULP_USERNAME} | jq -r '.results[0].pulp_href')
if [ "$USER_HREF" == "null" ] || [ -z "$USER_HREF" ]; then
    echo "Error: Could not find user $PULP_USERNAME in the response"
    exit 1
fi

# Set pulp user permissions
for role in "${ROLES[@]}"; do
    echo "Assigning $role..."
    response=$(curl -s -o /dev/null -w "%{http_code}\n" -u admin:${PULP_ADMIN_PASSWORD} \
         -X POST ${PULP_SERVER_URL}/pulp/api/v3/role-assignments/ \
         -H "Content-Type: application/json" \
         -d "{\"users\": [\"$USER_HREF\"], \"role\": \"$role\"}")

    if [ "$response" != "201" ]; then
        echo "Error: Failed to assign $role to $PULP_USERNAME"
    fi
done

# Print pulp_api status
echo "pulp_api is ready at $PULP_API_URL."
echo "Access Pulp API docs at $PULP_API_URL/pulp/api/v3/docs/"
