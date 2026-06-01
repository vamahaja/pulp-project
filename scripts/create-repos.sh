#!/bin/bash

set -euo pipefail

REPOS_YAML=""
PROJECT=""
BRANCH=""
LABELS=()

log() {
    echo "[pulp_create_repos] $*" >&2
}

show_help() {
    cat << 'EOF'
Usage: create-repos.sh [OPTIONS]

Creates Pulp repositories from a YAML definition.

Required:
    -p, --project <name>    Project name
    -f, --file <path>       Path to the YAML file

Optional:
    -l, --labels <labels>   Labels to filter the repositories
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
                REPOS_YAML="$2"
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
    if [[ -z "${REPOS_YAML}" ]]; then
        log "Error: -f / --file is required. Use --help for usage."
        exit 1
    fi
    if [[ -z "${PROJECT}" ]]; then
        log "Error: -p / --project is required. Use --help for usage."
        exit 1
    fi
    if [[ ! -f "${REPOS_YAML}" ]]; then
        log "Error: YAML file not found or not a regular file: ${REPOS_YAML}"
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

get_repos() {
    local params=".$PROJECT[][]"

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
    
    yq "$params" "$REPOS_YAML" --output-format=json
}

create_repos() {
    if [[ ${#LABELS[@]} -gt 0 ]]; then
        log "Applying label filters: ${LABELS[*]}"
    fi

    local repos
    repos=$(get_repos)
    local count
    count=$(echo "$repos" | jq -s 'length')
    log "Repositories to process: ${count}"

    echo "$repos" | jq -c '.' | while read -r repo; do
        local name=$(echo "$repo" | jq -r '.name')
        local labels=$(echo "$repo" | jq -r '.labels')
        local retain_repo_versions
        retain_repo_versions=$(echo "$repo" | jq -r '.retain_repo_versions // empty')
        local retain_flag=()
        if [[ -n "$retain_repo_versions" && "$retain_repo_versions" != "None" ]]; then
            retain_flag=(--retain-repo-versions "$retain_repo_versions")
        fi
        local distro=$(echo "$repo" | jq -r '.labels[].distro | select(. != null)')

        if [[ "$distro" == "ubuntu" ]]; then
            if ! pulp deb repository show --name "$name" &>/dev/null; then
                log "Creating deb repository: ${name}"
                pulp deb repository create \
                    --name "$name" \
                    "${retain_flag[@]}"
            else
                log "Deb repository already exists: ${name} (skipping create)"
            fi
        else
            if ! pulp rpm repository show --name "$name" &>/dev/null; then
                local labels_json=$(echo "$labels" | jq 'add')
                log "Creating rpm repository: ${name} with labels: ${labels_json}"
                pulp rpm repository create \
                    --name "$name" \
                    --no-autopublish \
                    "${retain_flag[@]}" \
                    --labels "$labels_json"
            else
                log "RPM repository already exists: ${name} (skipping create)"
            fi
        fi
    done
}

main() {
    parse_arguments "$@"
    validate_params
    setup_pulp_cmd

    log "Starting repository creation for project=${PROJECT} from ${REPOS_YAML}"
    create_repos
    log "Finished repository creation successfully !!!"
}

main "$@"
