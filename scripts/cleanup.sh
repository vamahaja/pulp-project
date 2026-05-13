#!/bin/bash

set -euo pipefail


CLEANUP_YAML=""

log() {
    echo "[pulp_cleanup] $*" >&2
}

show_help() {
    cat << 'EOF'
Usage: cleanup.sh [OPTIONS]

Cleans up Pulp resources.

Required:
    -f, --file <path>       Path to the YAML file

Optional:
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
                CLEANUP_YAML="$2"
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
    if [[ -z "${CLEANUP_YAML}" ]]; then
        echo "Error: -f / --file is required. Use --help for usage."
        exit 1
    fi
    log "Validating configuration file: ${CLEANUP_YAML}"
    if [[ ! -f "${CLEANUP_YAML}" ]]; then
        log "Error: YAML file not found or not a regular file: ${CLEANUP_YAML}"
        exit 1
    fi
    if ! yq '.' "${CLEANUP_YAML}" >/dev/null; then
        log "Error: Invalid YAML or unable to parse: ${CLEANUP_YAML}"
        exit 1
    fi
    log "Configuration file is present and valid YAML"
}

setup_pulp_cmd() {
    log "Validating Pulp command: pulp"
    if ! pulp status; then
        log "Error: Failed to validate Pulp command: pulp"
        exit 1
    fi
    log "Pulp command validated successfully"
}

prune_rpm_packages() {
    log "Applying RPM prune policy from ${CLEANUP_YAML}"
    local prune_rpm_cmd="pulp rpm prune-packages"

    local keep_days
    keep_days=$(yq -r '.rpm.keep_days' "$CLEANUP_YAML")
    if [[ "$keep_days" != "null" && -n "$keep_days" ]]; then
        prune_rpm_cmd+=" --keep-days $keep_days"
        log "RPM prune: keep packages newer than ${keep_days} day(s)"
    else
        log "RPM prune: keep_days not set in YAML (pulp CLI defaults apply)"
    fi

    if [[ $(yq -r '.rpm.all_repositories' "$CLEANUP_YAML") == "true" ]]; then
        prune_rpm_cmd+=" --all-repositories"
        log "RPM prune: targeting all repositories (--all-repositories)"
    else
        local repos
        repos=$(yq -r '.rpm.repositories[]' "$CLEANUP_YAML")
        local repo_list=()
        for repo in $repos; do
            prune_rpm_cmd+=" --repository $repo"
            repo_list+=("$repo")
        done
        log "RPM prune: scoping to ${#repo_list[@]} named repositories (${repo_list[*]})"
    fi

    log "Running: ${prune_rpm_cmd}"
    eval "$prune_rpm_cmd"
    log "RPM package prune completed successfully"
}

cutoff_date_for_keep_days() {
    local days="$1"
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
        log "Error: keep_days must be a non-negative integer, got: ${days}"
        exit 1
    fi
    date -d "-${days} days" +%Y-%m-%d
}

prune_task_states() {
    log "Applying task purge policy from ${CLEANUP_YAML}"
    local prune_task_cmd="pulp task purge"

    local keep_days
    keep_days=$(yq -r '.task.keep_days' "$CLEANUP_YAML")
    if [[ "$keep_days" == "null" || -z "$keep_days" ]]; then
        log "Task prune: keep_days not set in YAML (pulp CLI defaults apply)"
    else
        local finished_before
        finished_before=$(cutoff_date_for_keep_days "$keep_days")
        prune_task_cmd+=" --finished-before ${finished_before}"
        log "Task purge: removing tasks finished before ${finished_before} (keep_days=${keep_days})"
    fi

    local states
    states=$(yq -r '.task.state[]' "$CLEANUP_YAML")
    for state in $states; do
        prune_task_cmd+=" --state ${state}"
    done

    log "Running: ${prune_task_cmd}"
    eval "${prune_task_cmd}"
    log "Task purge completed successfully"
}

orphan_cleanup() {
    log "Applying orphan content purge policy from ${CLEANUP_YAML}"
    local orphan_cleanup_cmd="pulp orphan cleanup"

    local protection_time
    protection_time=$(yq -r '.orphan.protection_time' "$CLEANUP_YAML")
    if [[ "$protection_time" != "null" && -n "$protection_time" ]]; then
        orphan_cleanup_cmd+=" --protection-time ${protection_time}"
        log "Orphan cleanup: protecting content for ${protection_time} seconds"
    else
        log "Orphan cleanup: protection_time not set in YAML (pulp CLI defaults apply)"
    fi

    log "Running: ${orphan_cleanup_cmd}"
    eval "${orphan_cleanup_cmd}"
    log "Orphan content purge completed successfully"
}

main() {
    parse_arguments "$@"
    validate_params
    setup_pulp_cmd

    log "Starting Pulp cleanup ..."
    prune_rpm_packages
    prune_task_states
    orphan_cleanup
    log "Pulp cleanup finished successfully !"
}

main "$@"
