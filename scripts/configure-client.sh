#!/bin/bash

# Set error handling
set -euo pipefail

# Default values
PROJECT=${PROJECT:-"ceph"}
PULP_ADMIN_USERNAME=${PULP_ADMIN_USERNAME:-"admin"}
PULP_ADMIN_PASSWORD=${PULP_ADMIN_PASSWORD:-"pulp123"}

# Show help message
show_help() {
  cat << 'EOF'
Usage: configure-client.sh [OPTIONS]

Set up a Pulp client configuration.

Required:
    --username USERNAME     Username for authentication
    --password PASSWORD     Password for authentication
    --set-user-permissions  Add user permissions to the Pulp server (default: false)
    --overwrite             Overwrite existing configuration (default: false)

Environment:
    PULP_SERVER_URL     Pulp server URL
    PULP_ADMIN_USERNAME Pulp admin username (default: admin)
    PULP_ADMIN_PASSWORD Pulp admin password

Examples:
    configure-client.sh --help
    configure-client.sh --username cephuser --password cephuser123 --overwrite
    configure-client.sh --username cephuser --password cephuser123 --set-user-permissions --overwrite
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --username)
              USERNAME="$2"
              shift 2
              ;;
            --password)
              PASSWORD="$2"
              shift 2
              ;;
            --overwrite)
              OVERWRITE=true
              shift
              ;;
            --set-user-permissions)
              SET_USER_PERMISSIONS=true
              shift
              ;;
            -h|--help)
              show_help
              exit 0
              ;;
            *)
              echo "Error: unknown option '$1'" >&2
              exit 1
              ;;
        esac
    done
}

validate_parameters() {
    if [ -z "${PULP_SERVER_URL:-}" ]; then
        echo "Error: PULP_SERVER_URL is not set."
        echo "Please set it in the environment variables."
        exit 1
    fi

    if [ -z "${USERNAME:-}" ]; then
        echo "Error: --username is required."
        exit 1
    fi

    if [ -z "${PASSWORD:-}" ]; then
        echo "Error: --password is required."
        exit 1
    fi
}

configure_client() {
    pulp config create \
        --base-url "${PULP_SERVER_URL}" \
        --username "${USERNAME}" \
        --password "${PASSWORD}" \
        ${OVERWRITE:+--overwrite}

    if ! pulp status; then
        echo "Error: Pulp client is not configured correctly."
        exit 1
    fi
}

install_client() {
    # Install pulp client
    if ! command -v pulp &>/dev/null; then
        echo "Installing pulp client ..."
        pip install pulp-cli
    else
        echo "Pulp client is already installed."
    fi

    # Install pulp client plugins
    if pulp --version &>/dev/null; then
        echo "Installing pulp client plugins ..."
        pip install pulp-rpm pulp-deb pulp-cli-deb
    fi
}

set_user_permissions() {
    # Set pulp user permissions
    ROLES=(
        "rpm.rpmrepository_creator"
        "rpm.rpmremote_creator"
        "rpm.rpmdistribution_creator"
        "rpm.rpmpublication_creator"
        "deb.aptrepository_creator"
        "deb.aptremote_creator"
        "deb.aptdistribution_creator"
        "deb.aptpublication_creator"
        "deb.verbatimpublication_creator"
        "container.containerrepository_creator"
        "container.containerremote_creator"
        "container.containerdistribution_creator"
        "core.upload_creator"
    )

    for role in "${ROLES[@]}"; do
        echo "Assigning $role to user $USERNAME ..."

        # Grant cephuser the ability to create RPM repositories (ignore if already assigned)
        if ! output=$(pulp --username ${PULP_ADMIN_USERNAME} --password ${PULP_ADMIN_PASSWORD} \
            user role-assignment add \
            --username "${USERNAME}" \
            --role "$role" \
            --object "" 2>&1); then
            if [[ "$output" == *"already assigned"* ]]; then
                echo "Warning: Role $role already assigned to user $USERNAME, skipping ..."
            else
                echo "Error: Failed to assign role $role to user $USERNAME: $output" >&2
                exit 1
            fi
        fi
    done
}

# Parse arguments and validate parameters
parse_arguments "$@"
validate_parameters

# Install client and configure it
install_client
configure_client

# Set user permissions
if [ "${SET_USER_PERMISSIONS:-false}" = "true" ]; then
    set_user_permissions
fi

# Debug
echo "Pulp client is configured and working correctly."
