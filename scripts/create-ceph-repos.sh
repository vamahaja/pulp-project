#!/bin/bash

# Set error handling
set -euo pipefail

# Default values
PROJECT=${PROJECT:-"ceph"}

# Supported distros and their versions
declare -A DISTROS
DISTROS[ubuntu]="jammy noble"
DISTROS[centos]="8 9"
DISTROS[rocky]="10"

# Supported architecture
ARCHITECTURES=(noarch x86_64 aarch64)

# Supported ceph branches
CEPH_BRANCHES=(main reef squid tentacle)

# Container image repositories
CONTAINER_IMAGE_REPOSITORIES=(ceph ceph-ci)

# Parse user arguments
USER_DISTROS=()
USER_BRANCHES=()
USER_ARCHITECTURES=()
USER_CONTAINER_REPOSITORIES=()

# Show help message
show_help() {
    cat <<EOF
Usage: create-ceph-repos.sh [OPTIONS]

Create Pulp repositories for Ceph packages. Omit options to create repos for all
supported distros, branches.

Options:
    --distro LIST                   Comma-separated distros (default: all)
                                    Supported: ${!DISTROS[*]}

    --branches LIST                 Comma-separated Ceph branches (default: all)
                                    Supported: ${CEPH_BRANCHES[*]}

    --arch LIST                     Comma-separated architectures (default: all)
                                    Supported: ${ARCHITECTURES[*]}

    --container-repositories LIST   Comma-separated container image repositories (default: all)
                                    Supported: ${CONTAINER_IMAGE_REPOSITORIES[*]}

    -h, --help                      Show this help and exit

Environment:
    PROJECT                         Project name for repo names (default: ceph)

Examples:
    create-ceph-repos.sh --help
    create-ceph-repos.sh --distro ubuntu,centos --branches reef --arch x86_64,aarch64 --container-repositories ceph,ceph-ci
EOF
}

# Parse and validate user arguments.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --distro)
                [[ $# -lt 2 ]] && { echo "Error: --distro requires a value" >&2; exit 1; }
                IFS=',' read -ra USER_DISTROS <<< "$2"
                shift 2
                ;;
            --branches)
                [[ $# -lt 2 ]] && { echo "Error: --branches requires a value" >&2; exit 1; }
                IFS=',' read -ra USER_BRANCHES <<< "$2"
                shift 2
                ;;
            --arch)
                [[ $# -lt 2 ]] && { echo "Error: --arch requires a value" >&2; exit 1; }
                IFS=',' read -ra USER_ARCHITECTURES <<< "$2"
                shift 2
                ;;
            --container-repositories)
                [[ $# -lt 2 ]] && { echo "Error: --container-repositories requires a value" >&2; exit 1; }
                IFS=',' read -ra USER_CONTAINER_REPOSITORIES <<< "$2"
                shift 2
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

# Validate user arguments against supported distros and branches.
validate_user_args() {
    local a d b r

    validate_distro() {
        [[ -n "${DISTROS[$1]:-}" ]]
    }
    for d in "${USER_DISTROS[@]:-}"; do
        [[ -z "$d" ]] && continue
        d="${d// /}"
        if ! validate_distro "$d"; then
            echo "Error: unsupported distro '$d'. Supported: ${!DISTROS[*]}" >&2
            exit 1
        fi
    done

    validate_branch() {
        local x
        for x in "${CEPH_BRANCHES[@]}"; do [[ "$x" == "$1" ]] && return 0; done
        return 1
    }
    for b in "${USER_BRANCHES[@]:-}"; do
        [[ -z "$b" ]] && continue
        b="${b// /}"
        if ! validate_branch "$b"; then
            echo "Error: unsupported branch '$b'. Supported: ${CEPH_BRANCHES[*]}" >&2
            exit 1
        fi
    done

    validate_architecture() {
        local x
        for x in "${ARCHITECTURES[@]}"; do [[ "$x" == "$1" ]] && return 0; done
        return 1
    }
    for a in "${USER_ARCHITECTURES[@]:-}"; do
        [[ -z "$a" ]] && continue
        a="${a// /}"
        if ! validate_architecture "$a"; then
            echo "Error: unsupported architecture '$a'. Supported: ${ARCHITECTURES[*]}" >&2
            exit 1
        fi
    done

    validate_container_repository() {
        local x
        for x in "${CONTAINER_IMAGE_REPOSITORIES[@]}"; do [[ "$x" == "$1" ]] && return 0; done
        return 1
    }
    for r in "${USER_CONTAINER_REPOSITORIES[@]:-}"; do
        [[ -z "$r" ]] && continue
        r="${r// /}"
        if ! validate_container_repository "$r"; then
            echo "Error: unsupported container repository '$r'. Supported: ${CONTAINER_IMAGE_REPOSITORIES[*]}" >&2
            exit 1
        fi
    done
}

# Resolve which distros and branches to use (default: all).
resolve_supported_params() {
    trim_and_filter() {
        local -n arr=$1
        local -n out=$2
        out=()
        for x in "${arr[@]}"; do
            x="${x// /}"
            [[ -n "$x" ]] && out+=("$x")
        done
    }

    DISTROS_TO_USE=("${!DISTROS[@]}")
    if [[ ${#USER_DISTROS[@]} -gt 0 ]]; then
        trim_and_filter USER_DISTROS DISTROS_TO_USE
        [[ ${#DISTROS_TO_USE[@]} -eq 0 ]] && DISTROS_TO_USE=("${!DISTROS[@]}")
    fi

    BRANCHES_TO_USE=("${CEPH_BRANCHES[@]}")
    if [[ ${#USER_BRANCHES[@]} -gt 0 ]]; then
        trim_and_filter USER_BRANCHES BRANCHES_TO_USE
        [[ ${#BRANCHES_TO_USE[@]} -eq 0 ]] && BRANCHES_TO_USE=("${CEPH_BRANCHES[@]}")
    fi

    ARCHITECTURES_TO_USE=("${ARCHITECTURES[@]}")
    if [[ ${#USER_ARCHITECTURES[@]} -gt 0 ]]; then
        trim_and_filter USER_ARCHITECTURES ARCHITECTURES_TO_USE
        [[ ${#ARCHITECTURES_TO_USE[@]} -eq 0 ]] && ARCHITECTURES_TO_USE=("${ARCHITECTURES[@]}")
    fi

    CONTAINER_IMAGE_REPOSITORIES_TO_USE=("${CONTAINER_IMAGE_REPOSITORIES[@]}")
    if [[ ${#USER_CONTAINER_REPOSITORIES[@]} -gt 0 ]]; then
        trim_and_filter USER_CONTAINER_REPOSITORIES CONTAINER_IMAGE_REPOSITORIES_TO_USE
        [[ ${#CONTAINER_IMAGE_REPOSITORIES_TO_USE[@]} -eq 0 ]] && CONTAINER_IMAGE_REPOSITORIES_TO_USE=("${CONTAINER_IMAGE_REPOSITORIES[@]}")
    fi
}

# Create repositories for each branch distro
create_ceph_repos() {
    local branch distro distro_version repo_type repo_name

    for distro in "${DISTROS_TO_USE[@]}"; do
        for branch in "${BRANCHES_TO_USE[@]}"; do
            [[ -z "$distro" ]] && continue
            distro="${distro// /}"

            # Set repository type based on distro
            repo_type="rpm"
            if [[ "$distro" == "ubuntu" ]]; then
                repo_type="deb"
            fi

            # Create repository for each branch, distro version and architecture
            for distro_version in ${DISTROS[$distro]}; do
                for architecture in "${ARCHITECTURES_TO_USE[@]}"; do
                    repo_name="${PROJECT}-${branch}-${distro}-${distro_version}-${architecture}"
                    echo "Creating ${repo_type} repository ${repo_name} ..."
                    if ! pulp "${repo_type}" repository create --name "${repo_name}"; then
                        echo "Error: failed to create repository ${repo_name}" >&2
                        exit 1
                    fi
                done
            done
        done
    done
}

# Create container image repositories
create_container_image_repos() {
    for repo in "${CONTAINER_IMAGE_REPOSITORIES_TO_USE[@]}"; do
        echo "Creating container image repository ${repo} ..."

        if ! pulp container repository create --name "${repo}"; then
            echo "Error: failed to create container image repository ${repo}" >&2
            exit 1
        fi

        if ! pulp container distribution create --name "${repo}-dist" \
            --repository "${repo}" \
            --base-path "${repo}"; then
            echo "Error: failed to create container image distribution ${repo}-dist" >&2
            exit 1
        fi
    done
}

# Parse and validate user arguments
parse_args "$@"
validate_user_args
resolve_supported_params

# Create repositories
create_ceph_repos

# Create container image repositories
create_container_image_repos
