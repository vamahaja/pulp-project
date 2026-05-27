#!/bin/bash

# Set error handling
set -euo pipefail

log() {
    if [[ "${1:-}" == ERROR ]]; then
        echo "[ERROR] ${*:2}" >&2
    else
        echo "[INFO]  $*"
    fi
}

USERS_YAML="${USERS_YAML:-configs/users.yaml}"

show_help() {
  cat << 'EOF'
Usage: configure-client.sh [OPTIONS]

Set up a Pulp client configuration and optionally assign RBAC roles.

Required (one of):
    -f, --file FILE              Path to users YAML (e.g. configs/users.yaml).
                                 Required when using a role flag; admin and user
                                 credentials are read from the file.

Optional:
    --create-user LIST           Create users from YAML sections (admin,publisher,viewer)
    --set-permissions LIST       Assign roles from YAML (admin,publisher,viewer)
    --overwrite                  Overwrite existing pulp-cli configuration
    -h, --help                   Show this help

Environment:
    PULP_SERVER_URL     Pulp server URL (required)
    USERS_YAML          Default path for -f when flag is not provided (default: configs/users.yaml)

Examples:
    configure-client.sh -f configs/users.yaml --set-permissions admin,publisher,viewer --overwrite
    configure-client.sh -f configs/users.yaml --set-permissions publisher --overwrite
    configure-client.sh -f configs/users.yaml --create-user admin,publisher --overwrite
    configure-client.sh -f configs/users.yaml --create-user admin,publisher --set-permissions admin,publisher,viewer --overwrite
    configure-client.sh -f configs/users.yaml --overwrite
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--file)
                USERS_YAML="$2"
                shift 2
                ;;
            --overwrite)
                OVERWRITE=true
                shift
                ;;
            --set-permissions)
                if [[ $# -lt 2 ]]; then
                    log ERROR "--set-permissions requires a comma-separated list: admin,publisher,viewer"
                    exit 1
                fi
                SET_PERMISSIONS_LIST="$2"
                shift 2
                ;;
            --create-user)
                if [[ $# -lt 2 ]]; then
                    log ERROR "--create-user requires a comma-separated list: admin,publisher,viewer"
                    exit 1
                fi
                CREATE_USER_LIST="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log ERROR "Unknown option '$1'"
                exit 1
                ;;
        esac
    done
}

load_user_from_yaml() {
    local f="$1"
    local section="$2"

    if ! command -v yq >/dev/null 2>&1; then
        log ERROR "yq is required to read credentials from ${f}."
        exit 1
    fi
    if [[ ! -f "$f" ]]; then
        log ERROR "Config file not found: ${f}"
        exit 1
    fi

    # Admin credentials for role assignment (from .default.* — the built-in Django superuser)
    PULP_ADMIN_USERNAME=$(yq -r '.default.username' "$f")
    PULP_ADMIN_PASSWORD=$(yq -r '.default.password' "$f")

    # User credentials for pulp config create (from the requested section)
    USERNAME=$(yq -r ".${section}.username" "$f")
    PASSWORD=$(yq -r ".${section}.password" "$f")

    local v
    for v in PULP_ADMIN_USERNAME PULP_ADMIN_PASSWORD USERNAME PASSWORD; do
        if [[ -z "${!v:-}" || "${!v}" == "null" ]]; then
            log ERROR "${v} is empty or null in ${f} (section: ${section})."
            exit 1
        fi
    done
}

# Parse comma-separated admin|publisher|viewer list into the named array variable.
parse_user_type_list() {
    local list="$1"
    local -n _out=$2

    _out=()
    IFS=',' read -r -a values <<< "${list}"
    local raw section
    for raw in "${values[@]}"; do
        section="${raw//[[:space:]]/}"
        [[ -z "${section}" ]] && continue
        case "${section}" in
            admin|publisher|viewer)
                _out+=("${section}")
                ;;
            *)
                log ERROR "Invalid user type '${section}'. Use admin, publisher, or viewer."
                exit 1
                ;;
        esac
    done
}

validate_parameters() {
    if [ -z "${PULP_SERVER_URL:-}" ]; then
        log ERROR "PULP_SERVER_URL is not set."
        exit 1
    fi

    if [[ -n "${SET_PERMISSIONS_LIST:-}" || -n "${CREATE_USER_LIST:-}" ]]; then
        if [[ ! -f "${USERS_YAML}" ]]; then
            log ERROR "Config file not found: ${USERS_YAML}. Provide -f <file> or set USERS_YAML."
            exit 1
        fi
    fi

    _SET_PERMISSION_TYPES=()
    if [[ -n "${SET_PERMISSIONS_LIST:-}" ]]; then
        parse_user_type_list "${SET_PERMISSIONS_LIST}" _SET_PERMISSION_TYPES
        if [[ ${#_SET_PERMISSION_TYPES[@]} -eq 0 ]]; then
            log ERROR "--set-permissions must contain at least one valid type."
            exit 1
        fi
    fi

    _CREATE_USER_TYPES=()
    if [[ -n "${CREATE_USER_LIST:-}" ]]; then
        parse_user_type_list "${CREATE_USER_LIST}" _CREATE_USER_TYPES
        if [[ ${#_CREATE_USER_TYPES[@]} -eq 0 ]]; then
            log ERROR "--create-user must contain at least one valid type."
            exit 1
        fi
    fi
}

configure_client_with_credentials() {
    local cfg_username="$1"
    local cfg_password="$2"

    pulp config create \
        --base-url "${PULP_SERVER_URL}" \
        --username "${cfg_username}" \
        --password "${cfg_password}" \
        --no-verify-ssl \
        ${OVERWRITE:+--overwrite}

    if ! pulp status; then
        log ERROR "Pulp client is not configured correctly."
        exit 1
    fi
}

create_user_if_missing() {
    log "Creating user ${USERNAME} using admin credentials ..."

    local output
    if ! output=$(pulp --username "${PULP_ADMIN_USERNAME}" --password "${PULP_ADMIN_PASSWORD}" \
        user create \
        --username "${USERNAME}" \
        --password "${PASSWORD}" 2>&1); then
        if [[ "$output" == *"already exists"* || "$output" == *"unique"* || "$output" == *"409"* ]]; then
            log "User ${USERNAME} already exists, skipping creation."
        else
            log ERROR "Failed to create user ${USERNAME}: ${output}"
            exit 1
        fi
    else
        log "User ${USERNAME} created successfully."
    fi
}

install_client() {
    local pip_args=()
    if pip install --dry-run --break-system-packages pip &>/dev/null 2>&1; then
        pip_args+=(--break-system-packages)
    fi

    if ! command -v pulp &>/dev/null; then
        log "Installing pulp client ..."
        pip install "${pip_args[@]}" pulp-cli
    else
        log "Pulp client is already installed."
    fi

    if ! pip show pulp-cli-deb &>/dev/null; then
        log "Installing pulp client deb plugin ..."
        pip install "${pip_args[@]}" pulp-cli-deb
    else
        log "Pulp client deb plugin is already installed."
    fi
}

# Model-level role assignment (empty --object grants access to all objects of that type).
assign_roles() {
    local label="$1"
    shift
    local roles=("$@")

    log "Assigning ${label} roles to user ${USERNAME} ..."
    for role in "${roles[@]}"; do
        log "  Assigning ${role} ..."

        local output
        if ! output=$(pulp --username "${PULP_ADMIN_USERNAME}" --password "${PULP_ADMIN_PASSWORD}" \
            user role-assignment add \
            --username "${USERNAME}" \
            --role "$role" \
            --object "" 2>&1); then
            if [[ "$output" == *"already assigned"* ]]; then
                log "  Warning: Role ${role} already assigned, skipping ..."
            else
                log ERROR "Failed to assign role ${role} to user ${USERNAME}: ${output}"
                exit 1
            fi
        fi
    done
}

_ROLES=()
_SET_PERMISSION_TYPES=()
_CREATE_USER_TYPES=()

load_roles_for_section() {
    local section="$1"
    local f="${USERS_YAML}"

    _ROLES=()
    mapfile -t _ROLES < <(yq -r ".${section}.roles[]?" "$f" 2>/dev/null || true)

    local cleaned=()
    local r
    for r in "${_ROLES[@]}"; do
        [[ -n "$r" && "$r" != "null" ]] && cleaned+=("$r")
    done
    _ROLES=("${cleaned[@]}")

    if [[ ${#_ROLES[@]} -eq 0 ]]; then
        log ERROR "${f} must define a non-empty .${section}.roles list."
        exit 1
    fi
}

set_permissions_for_section() {
    local section="$1"
    load_user_from_yaml "${USERS_YAML}" "${section}"
    load_roles_for_section "${section}"
    assign_roles "${section}" "${_ROLES[@]}"
}

# Parse and validate
parse_arguments "$@"
validate_parameters

if [[ ${#_SET_PERMISSION_TYPES[@]} -gt 0 ]]; then
    TARGET_SECTION="${_SET_PERMISSION_TYPES[-1]}"
else
    TARGET_SECTION="publisher"
fi

if [[ ! -f "${USERS_YAML}" ]]; then
    log ERROR "Config file not found: ${USERS_YAML}. Provide -f <file> or set USERS_YAML."
    exit 1
fi

load_user_from_yaml "${USERS_YAML}" "${TARGET_SECTION}"

install_client

if [[ ${#_CREATE_USER_TYPES[@]} -gt 0 ]]; then
    configure_client_with_credentials "${PULP_ADMIN_USERNAME}" "${PULP_ADMIN_PASSWORD}"
    for section in "${_CREATE_USER_TYPES[@]}"; do
        load_user_from_yaml "${USERS_YAML}" "${section}"
        create_user_if_missing
    done
    load_user_from_yaml "${USERS_YAML}" "${TARGET_SECTION}"
fi

configure_client_with_credentials "${USERNAME}" "${PASSWORD}"

for section in "${_SET_PERMISSION_TYPES[@]}"; do
    set_permissions_for_section "${section}"
done

log "Pulp client is configured and working correctly."
