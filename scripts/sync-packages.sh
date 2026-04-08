#!/bin/bash
set -euo pipefail

# Chacra base URL
CHACRA_BASE_URL=${CHACRA_BASE_URL:-"https://1.chacra.ceph.com/r"}

# Default repository parameters
PROJECT="ceph"
FLAVOR="default"

# Supported distros and their versions
declare -A DISTROS
DISTROS[ubuntu]="jammy noble"
DISTROS[centos]="9"
DISTROS[rocky]="10"

# Supported architectures per distro
declare -A ARCHITECTURES
ARCHITECTURES[all]="x86_64 arm64 noarch aarch64 SRPMS"
ARCHITECTURES[ubuntu]="x86_64 arm64"
ARCHITECTURES[centos]="noarch x86_64 aarch64 SRPMS"
ARCHITECTURES[rocky]="noarch x86_64 aarch64 SRPMS"

# Supported ceph branches
CEPH_BRANCHES=(main reef squid tentacle)

# Parse user arguments
USER_DISTROS=()
USER_BRANCHES=()
USER_ARCHITECTURES=()

# Poll interval and timeout
INTERVAL_SECONDS=${INTERVAL_SECONDS:-10}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-300}


show_help() {
  cat << 'EOF'
Usage: sync-packages.sh [OPTIONS]

Required:
    --sha1 <sha1>            SHA1 commit hash
    --version <version>      Package version string

Optional:
    --distros LIST          Comma-separated distros (default: all)
                                Supported: ${!DISTROS[*]}
    --branches LIST         Comma-separated Ceph branches (default: all)
                                Supported: ${CEPH_BRANCHES[*]}
    --archs LIST            Comma-separated architectures (default: all per distro)
                                ubuntu: ${ARCHITECTURES[ubuntu]}
                                centos: ${ARCHITECTURES[centos]}
                                rocky:  ${ARCHITECTURES[rocky]}
    -h, --help              Show this help and exit
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --sha1)
                SHA1="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --distros)
                [[ $# -lt 2 ]] && { echo "Error: --distros requires a value" >&2; exit 1; }
                IFS=',' read -ra USER_DISTROS <<< "$2"
                shift 2
                ;;
            --branches)
                [[ $# -lt 2 ]] && { echo "Error: --branches requires a value" >&2; exit 1; }
                IFS=',' read -ra USER_BRANCHES <<< "$2"
                shift 2
                ;;
            --archs)
                [[ $# -lt 2 ]] && { echo "Error: --archs requires a value" >&2; exit 1; }
                IFS=',' read -ra USER_ARCHITECTURES <<< "$2"
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

validate_params() {
    for distro in "${USER_DISTROS[@]}"; do
        distro="${distro// /}"
        if [[ ! " ${!DISTROS[@]} " =~ " ${distro} " ]]; then
            echo "Error: unsupported distro '$distro'. "
            echo "Supported: ${!DISTROS[@]}"
            exit 1
        fi
    done

    for branch in "${USER_BRANCHES[@]}"; do
        branch="${branch// /}"
        if [[ ! " ${CEPH_BRANCHES[@]} " =~ " ${branch} " ]]; then
            echo "Error: unsupported branch '$branch'. " 
            echo "Supported: ${CEPH_BRANCHES[*]}"
            exit 1
        fi
    done

    for architecture in "${USER_ARCHITECTURES[@]}"; do
        architecture="${architecture// /}"
        if [[ ! " ${ARCHITECTURES[all]} " =~ " ${architecture} " ]]; then
            echo "Error: unsupported architecture '$architecture'."
            echo" Supported: ${ARCHITECTURES[all]}"
            exit 1
        fi
    done

    if [[ ${#USER_DISTROS[@]} -eq 0 ]]; then
        USER_DISTROS=("${!DISTROS[@]}")
    fi
    if [[ ${#USER_BRANCHES[@]} -eq 0 ]]; then
        USER_BRANCHES=("${CEPH_BRANCHES[@]}")
    fi
    if [[ ${#USER_ARCHITECTURES[@]} -eq 0 ]]; then
        USER_ARCHITECTURES=("${ARCHITECTURES[all]}")
    fi
}

check_for_chacra_connection() {
    echo "Checking for Chacra connection..."
    local code
    local url="${CHACRA_BASE_URL%/r}"
    code=$(curl -sS -g -o /dev/null -w "%{http_code}" -L -I "$url" 2>/dev/null || true)
    if [[ "$code" != "200" ]]; then
        echo "Error: could not reach Chacra (HTTP $code)" >&2
        exit 1
    fi
    echo "Chacra connection OK (HTTP $code)"
}

resolve_pkg_type() {
    local distro="$1"
    case "$distro" in
        ubuntu)        echo "deb" ;;
        centos|rocky)  echo "rpm" ;;
        *)
            echo "Error: unsupported distro '$distro'" >&2
            exit 1
            ;;
    esac
}

validate_chacra_upstream_url() {
    local url=$1
    local code
    code=$(curl -sS -g -o /dev/null -w "%{http_code}" -L -I "$url" 2>/dev/null || true)
    if [[ "$code" == "404" ]]; then
        echo "Warning: Chacra URL not valid: $url" >&2
        return 1
    fi

    if [[ "$code" != "200" ]]; then
        echo "Error: could not reach Chacra (HTTP $code): $url" >&2
        exit 1
    fi

    return 0
}

apply_shaman_distribution_labels() {
    local pkg_type branch distro distro_version dist_name
    pkg_type="$1"
    branch="$2"
    distro="$3"
    distro_version="$4"
    dist_name="$5"

    local lookup_flag="--name"
    if [[ "$pkg_type" == "rpm" ]]; then
        lookup_flag="--distribution"
    fi

    echo "Applying Shaman compatibility labels to Distribution: $dist_name"
    local i
    local -a labels=(
        ref "$branch"
        arch "$architecture"
        sha1 "$SHA1"
        distro "$distro"
        distro_version "$distro_version"
        flavors "$FLAVOR"
        project "$PROJECT"
        version "$VERSION"
    )
    for ((i = 0; i < ${#labels[@]}; i += 2)); do
        pulp "$pkg_type" distribution label set "$lookup_flag" "$dist_name" \
            --key "${labels[i]}" --value "${labels[i + 1]}"
    done
}

create_publication_and_distribution() {
    local pkg_type repo_name dist_name dist_base_path
    pkg_type="$1"
    repo_name="$2"
    dist_name="$3"
    dist_base_path="$4"

    echo "Creating Publication: $repo_name"
    local pub_href
    pub_href=$(pulp "$pkg_type" publication create --repository "$repo_name" | jq -r '.pulp_href')

    echo "Creating Distribution: $dist_name"
    if pulp "$pkg_type" distribution show --name "$dist_name" &>/dev/null; then
        pulp "$pkg_type" distribution update --name "$dist_name" --publication "$pub_href"
    else
        pulp "$pkg_type" distribution create --name "$dist_name" \
            --base-path "$dist_base_path" \
            --publication "$pub_href"
    fi
}

poll_until_sync_task_done() {
    local task_href=$1
    local deadline=""
    if [[ -n "${TIMEOUT_SECONDS}" ]]; then
        deadline=$((SECONDS + "${TIMEOUT_SECONDS}"))
    fi
    local state
    while true; do
        state=$(LC_ALL=C pulp --format json task show --href "$task_href" | jq -r .state)
        case "$state" in
            completed)
                echo "Sync task completed."
                return 0
                ;;
            failed|canceled)
                echo "Sync task ended with state: $state" >&2
                LC_ALL=C pulp --format json task show --href "$task_href" | jq .error >&2 || true
                return 1
                ;;
            waiting|running|canceling)
                echo "Sync task state: $state"
                if [[ -n "$deadline" ]] && (( SECONDS > deadline )); then
                    echo "Error: sync timed out after ${TIMEOUT_SECONDS}s" >&2
                    return 1
                fi
                sleep "$INTERVAL_SECONDS"
                ;;
            *)
                echo "Error: unknown task state from Pulp: $state" >&2
                return 1
                ;;
        esac
    done
}

configure_remote_and_sync_repository() {
    local pkg_type repo_name remote_name upstream_url
    pkg_type="$1"
    repo_name="$2"
    remote_name="$3"
    upstream_url="$4"

    echo "Configuring Pulp Remote: $remote_name for Repository: $repo_name"
    if pulp "$pkg_type" remote show --name "$remote_name" &>/dev/null; then
        pulp "$pkg_type" remote update --name "$remote_name" --url "$upstream_url"
    else
        pulp "$pkg_type" remote create --name "$remote_name" --url "$upstream_url"
    fi

    echo "Syncing Repository $repo_name from Chacra ..."
    local sync_out sync_exit=0
    sync_out=$(LC_ALL=C pulp -b --format json "$pkg_type" repository sync \
        --name "$repo_name" --remote "$remote_name" 2>&1) || sync_exit=$?

    if [[ "$sync_exit" -ne 0 ]]; then
        printf '%s\n' "$sync_out" >&2
        exit "$sync_exit"
    fi

    local task_href
    task_href=$(printf '%s\n' "$sync_out" | sed -n 's/.*Started background task \(.*\)/\1/p' | tail -n1)
    if [[ -z "$task_href" ]]; then
        task_href=$(printf '%s\n' "$sync_out" | jq -r 'if type == "object" then (.pulp_href // .task // empty) else empty end' 2>/dev/null | head -n1)
    fi
    if [[ -z "$task_href" ]]; then
        echo "Error: could not determine repository sync task href. Command output:" >&2
        printf '%s\n' "$sync_out" >&2
        exit 1
    fi

    poll_until_sync_task_done "$task_href"
}

sync_chacra_target_into_pulp() {
    local branch distro distro_version architecture
    branch="$1"
    distro="$2"
    distro_version="$3"
    architecture="$4"

    echo "Syncing Chacra target into Pulp for Branch: $branch, Distro: $distro, Distro Version: $distro_version, Architecture: $architecture"
    local pkg_type repo_name remote_name dist_name dist_base_path upstream_url
    pkg_type=$(resolve_pkg_type "$distro")
    repo_name="${PROJECT}-${branch}-${distro}-${distro_version}-${architecture}"
    remote_name="chacra-${branch}-${distro}-${distro_version}-${architecture}-${SHA1: -8}"
    dist_name="dist-${branch}-${distro}-${distro_version}-${architecture}-${SHA1: -8}"
    dist_base_path="repos/${PROJECT}/${branch}/${SHA1}/${distro}/${distro_version}/flavors/${FLAVOR}/${architecture}"
    upstream_url="${CHACRA_BASE_URL}/${PROJECT}/${branch}/${SHA1}/${distro}/${distro_version}/flavors/${FLAVOR}/${architecture}/"

    if ! validate_chacra_upstream_url "$upstream_url"; then
        return 1
    fi

    configure_remote_and_sync_repository "$pkg_type" "$repo_name" "$remote_name" "$upstream_url"
    create_publication_and_distribution "$pkg_type" "$repo_name" "$dist_name" "$dist_base_path"
    apply_shaman_distribution_labels "$pkg_type" "$branch" "$distro" "$distro_version" "$dist_name"
}

# Parse and validate
parse_arguments "$@"
validate_params
check_for_chacra_connection

# Sync packages for each branch
for BRANCH in "${USER_BRANCHES[@]}"; do
    for DISTRO in "${USER_DISTROS[@]}"; do
        for DISTRO_VERSION in ${DISTROS[$DISTRO]}; do
            for ARCHITECTURE in ${USER_ARCHITECTURES}; do
                if [[ ! " ${ARCHITECTURES[$DISTRO]} " =~ " ${ARCHITECTURE} " ]]; then
                    echo "Warning: unsupported architecture '$ARCHITECTURE' for distro '$DISTRO'" >&2
                    continue
                fi
                sync_chacra_target_into_pulp "$BRANCH" "$DISTRO" "$DISTRO_VERSION" "$ARCHITECTURE"
            done
        done
    done
done
