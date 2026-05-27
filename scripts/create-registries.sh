#!/bin/bash

set -euo pipefail

REGISTRIES_YAML=""
PROJECT=""
LABELS=()

log() {
    echo "[pulp_create_registries] $*" >&2
}

show_help() {
    cat << 'EOF'
Usage: create-registries.sh [OPTIONS]

Creates Pulp container repositories and distributions from a YAML definition.

Required:
    -p, --project <name>    Project name
    -f, --file <path>       Path to the YAML file (e.g. configs/registries.yaml)

Optional:
    -l, --labels <labels>   Labels to filter registries (key=value, comma-separated)
    -h, --help              Show this help
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--file)
                if [[ $# -lt 2 ]]; then
                    log "Error: $1 requires a value."
                    exit 1
                fi
                REGISTRIES_YAML="$2"
                shift 2
                ;;
            -p|--project)
                if [[ $# -lt 2 ]]; then
                    log "Error: $1 requires a value."
                    exit 1
                fi
                PROJECT="$2"
                shift 2
                ;;
            -l|--labels)
                if [[ $# -lt 2 ]]; then
                    log "Error: $1 requires a value."
                    exit 1
                fi
                IFS=',' read -r -a LABELS <<< "$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log "Error: Unknown option: $1"
                exit 1
                ;;
            *)
                log "Error: Unexpected argument: $1"
                exit 1
                ;;
        esac
    done
}

validate_params() {
    if [[ -z "${REGISTRIES_YAML}" ]]; then
        log "Error: -f / --file is required. Use --help for usage."
        exit 1
    fi
    if [[ -z "${PROJECT}" ]]; then
        log "Error: -p / --project is required. Use --help for usage."
        exit 1
    fi
    if [[ ! -f "${REGISTRIES_YAML}" ]]; then
        log "Error: YAML file not found or not a regular file: ${REGISTRIES_YAML}"
        exit 1
    fi
}

setup_pulp_cmd() {
    log "Validating Pulp command: pulp"
    if ! pulp status; then
        log "Error: Failed to validate Pulp command: pulp"
        exit 1
    fi
    log "Pulp command validated successfully"
}

get_registries() {
    local params=".$PROJECT.repositories[]"

    local filters=()
    for label in "${LABELS[@]}"; do
        local key=$(echo "$label" | cut -d '=' -f 1)
        local value=$(echo "$label" | cut -d '=' -f 2)

        filters+=("(.labels[].$key == \"$value\")")
    done

    if [[ ${#filters[@]} -gt 0 ]]; then
        local joined_filter
        joined_filter=$(printf " and %s" "${filters[@]}")
        joined_filter=${joined_filter# and }

        params+=" | select($joined_filter)"
    fi

    yq "$params" "$REGISTRIES_YAML" --output-format=json
}

create_registries() {
    if [[ ${#LABELS[@]} -gt 0 ]]; then
        log "Applying label filters: ${LABELS[*]}"
    fi

    local registries
    registries=$(get_registries)
    local count
    count=$(echo "$registries" | jq -s 'length')
    log "Container registries to process: ${count}"

    echo "$registries" | jq -c '.' | while read -r registry; do
        local name=$(echo "$registry" | jq -r '.name')
        local labels=$(echo "$registry" | jq -r '.labels')
        local retain_repo_versions=$(echo "$registry" | jq -r '.retain_repo_versions')
        local dist_name=$(echo "$registry" | jq -r '.distribution')
        local base_path=$(echo "$registry" | jq -r '.base_path')
        local labels_json=$(echo "$labels" | jq 'add')

        if ! pulp container repository show --name "$name" &>/dev/null; then
            log "Creating container repository: ${name} with labels: ${labels_json}"
            pulp container repository create \
                --name "$name" \
                --retain-repo-versions "$retain_repo_versions" \
                --labels "$labels_json"
        else
            log "Container repository already exists: ${name} (skipping create)"
        fi

        if ! pulp container distribution show --name "$dist_name" &>/dev/null; then
            log "Creating container distribution: ${dist_name} (repository=${name}, base_path=${base_path})"
            pulp container distribution create \
                --name "$dist_name" \
                --repository "$name" \
                --base-path "$base_path"
        else
            log "Container distribution already exists: ${dist_name} (skipping create)"
        fi
    done
}

main() {
    parse_arguments "$@"
    validate_params
    setup_pulp_cmd

    log "Starting container registry creation for project=${PROJECT} from ${REGISTRIES_YAML}"
    create_registries
    log "Finished container registry creation successfully !!!"
}

main "$@"
