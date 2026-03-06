#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -euxo pipefail

echo "Starting Pulp Project deployment prep ..."

# Set database password
export PULP_DB_NAME=${PULP_DB_NAME:-"pulp"}
export PULP_DB_USER=${PULP_DB_USER:-"pulp"}
export PULP_DB_PASSWORD=${PULP_DB_PASSWORD:-"pulpdb123"}

# Set PULP_API_URL using host IP (fallback to localhost)
PULP_IP=$(hostname -I | awk '{print $1}')
export PULP_API_URL="http://${PULP_IP}:24817"

# Check if a base directory was provided
if [ -z "${1:-}" ]; then
    echo "Error: No deployment directory provided."
    echo "Usage: ./deploy.sh /path/to/your/pulp_data"
    exit 1
fi

# Set and export base directory for dir-type volumes (used by podman-compose)
export PULP_BASE_DIR="$(realpath "$1")"
echo "Using PULP_BASE_DIR=$PULP_BASE_DIR"

# Create required directories for pulp project (dir-type volumes)
echo "Create directory-type volume dirs in $PULP_BASE_DIR for podman compose ..."
mkdir -p "${PULP_BASE_DIR}"/{pgsql,pulp_storage,settings,redis_data,nginx_conf}

# Copy nginx.conf to the deployment directory
echo "Copy nginx.conf to $PULP_BASE_DIR ..."
cp nginx.conf "${PULP_BASE_DIR}/nginx_conf/nginx.conf"

# Generate SSL certificate and key
mkdir -p ${PULP_BASE_DIR}/settings/certs
openssl rand -base64 32 > ${PULP_BASE_DIR}/settings/certs/database_fields.symmetric.key

# Set execute permissions for base directory
podman unshare chmod -R 755 ${PULP_BASE_DIR}

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

echo "pulp_api is ready at $PULP_API_URL."