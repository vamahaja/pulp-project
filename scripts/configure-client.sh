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
    --set-admin-permissions      Assign full management roles to the admin user
    --set-publisher-permissions  Assign create/upload roles to the publisher user
    --set-viewer-permissions     Assign read-only viewer roles to the viewer user
    --overwrite                  Overwrite existing pulp-cli configuration
    -h, --help                   Show this help

Environment:
    PULP_SERVER_URL     Pulp server URL (required)
    USERS_YAML          Default path for -f when flag is not provided (default: configs/users.yaml)

Examples:
    configure-client.sh -f configs/users.yaml --set-admin-permissions --overwrite
    configure-client.sh -f configs/users.yaml --set-publisher-permissions --overwrite
    configure-client.sh -f configs/users.yaml --set-viewer-permissions --overwrite
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
            --set-admin-permissions)
                SET_ADMIN_PERMISSIONS=true
                shift
                ;;
            --set-publisher-permissions)
                SET_PUBLISHER_PERMISSIONS=true
                shift
                ;;
            --set-viewer-permissions)
                SET_VIEWER_PERMISSIONS=true
                shift
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

validate_parameters() {
    if [ -z "${PULP_SERVER_URL:-}" ]; then
        log ERROR "PULP_SERVER_URL is not set."
        exit 1
    fi

    local perm_flags=0
    [ "${SET_ADMIN_PERMISSIONS:-false}" = "true" ]     && perm_flags=$((perm_flags + 1))
    [ "${SET_VIEWER_PERMISSIONS:-false}" = "true" ]    && perm_flags=$((perm_flags + 1))
    [ "${SET_PUBLISHER_PERMISSIONS:-false}" = "true" ] && perm_flags=$((perm_flags + 1))
    if [ "$perm_flags" -gt 1 ]; then
        log ERROR "Use only one of --set-admin-permissions, --set-viewer-permissions, or --set-publisher-permissions per run."
        exit 1
    fi

    if [ "$perm_flags" -gt 0 ] && [[ ! -f "${USERS_YAML}" ]]; then
        log ERROR "Config file not found: ${USERS_YAML}. Provide -f <file> or set USERS_YAML."
        exit 1
    fi
}

configure_client() {
    pulp config create \
        --base-url "${PULP_SERVER_URL}" \
        --username "${USERNAME}" \
        --password "${PASSWORD}" \
        --no-verify-ssl \
        ${OVERWRITE:+--overwrite}

    if ! pulp status; then
        log ERROR "Pulp client is not configured correctly."
        exit 1
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

# Role lists come only from configs/users.yaml; yq required.
_ROLES=()

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

set_admin_permissions() {
    load_roles_for_section "admin"
    assign_roles "admin (full management)" "${_ROLES[@]}"
}

set_publisher_permissions() {
    load_roles_for_section "publisher"
    assign_roles "publisher (create / upload)" "${_ROLES[@]}"
}

set_viewer_permissions() {
    load_roles_for_section "viewer"
    assign_roles "viewer (read-only)" "${_ROLES[@]}"
}

# Parse and validate
parse_arguments "$@"
validate_parameters

# If a role flag is given, user/admin credentials come from YAML; configure accordingly.
if [ "${SET_ADMIN_PERMISSIONS:-false}" = "true" ]; then
    load_user_from_yaml "${USERS_YAML}" "admin"
elif [ "${SET_PUBLISHER_PERMISSIONS:-false}" = "true" ]; then
    load_user_from_yaml "${USERS_YAML}" "publisher"
elif [ "${SET_VIEWER_PERMISSIONS:-false}" = "true" ]; then
    load_user_from_yaml "${USERS_YAML}" "viewer"
else
    if [[ ! -f "${USERS_YAML}" ]]; then
        log ERROR "Config file not found: ${USERS_YAML}. Provide -f <file> or set USERS_YAML."
        exit 1
    fi
    # Default: load publisher credentials for pulp config
    load_user_from_yaml "${USERS_YAML}" "publisher"
fi

# Install and configure pulp CLI
install_client
configure_client

# Assign RBAC roles
if [ "${SET_ADMIN_PERMISSIONS:-false}" = "true" ]; then
    set_admin_permissions
fi
if [ "${SET_VIEWER_PERMISSIONS:-false}" = "true" ]; then
    set_viewer_permissions
fi
if [ "${SET_PUBLISHER_PERMISSIONS:-false}" = "true" ]; then
    set_publisher_permissions
fi

log "Pulp client is configured and working correctly."
