#!/bin/bash

set -euo pipefail

REPOS_YAML=""
PROJECT=""
BRANCH=""
LABELS=()

show_help() {
    cat << 'EOF'
Usage: create-ceph-repos.sh [OPTIONS]

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
                echo "Error: $1 requires a value."
                exit 1
                fi
                REPOS_YAML="$2"
                shift 2
                ;;
            -p|--project)
                if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value."
                exit 1
                fi
                PROJECT="$2"
                shift 2
                ;;
            -l|--labels)
                if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value."
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
                echo "Error: Unknown option: $1"
                exit 1
                ;;
            *)
                echo "Error: Unexpected argument: $1"
                exit 1
                ;;
        esac
    done
}

validate_params() {
    if [[ -z "${REPOS_YAML}" ]]; then
        echo "Error: -f / --file is required. Use --help for usage."
        exit 1
    fi
    if [[ -z "${PROJECT}" ]]; then
        echo "Error: -p / --project is required. Use --help for usage."
        exit 1
    fi
    if [[ ! -f "${REPOS_YAML}" ]]; then
        echo "Error: YAML file not found or not a regular file: ${REPOS_YAML}"
        exit 1
    fi
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
    local repos=$(get_repos)
    echo "$repos" | jq -c '.' | while read -r repo; do
        local name=$(echo "$repo" | jq -r '.name')
        local labels=$(echo "$repo" | jq -r '.labels')
        local retain_repo_versions=$(echo "$repo" | jq -r '.retain_repo_versions')
        local distro=$(echo "$repo" | jq -r '.labels[].distro | select(. != null)')

        if [[ "$distro" == "ubuntu" ]]; then
            if ! pulp deb repository show --name "$name" &>/dev/null; then
                echo "Creating deb repository: $name"
                pulp deb repository create \
                    --name "$name" \
                    --retain-repo-versions "$retain_repo_versions"
            else
                echo "Deb repository already exists: $name"
            fi
        else
            if ! pulp rpm repository show --name "$name" &>/dev/null; then
                local labels_json=$(echo "$labels" | jq 'add')
                echo "Creating rpm repository: $name with labels: $labels_json"
                pulp rpm repository create \
                    --name "$name" \
                    --retain-repo-versions "$retain_repo_versions" \
                    --labels "$labels_json"
            else
                echo "RPM repository already exists: $name"
            fi
        fi
    done
}

main() {
    parse_arguments "$@"
    validate_params
    create_repos
}

main "$@"
