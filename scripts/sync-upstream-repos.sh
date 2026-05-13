#!/bin/bash

# Creates Pulp remotes for upstream OS package repositories and mirrors them
# locally so OCP nodes can consume packages without hitting the public internet.
#
# For each configured upstream repo the script:
#   1. Creates a Pulp repository (if not already present)
#   2. Creates or updates a Pulp remote pointing to the upstream URL
#   3. Syncs the repository (metadata only by default via on_demand policy)
#   4. Creates a publication and distribution for internal consumption
#
# Safe to re-run — all operations are idempotent.

set -euo pipefail

# Remote download policy.
#   on_demand  – Pulp proxies and caches content when first requested (recommended
#                for large upstream repos; avoids downloading the full repo tree).
#   immediate  – Download all content immediately during sync.
#   streamed   – Stream content on request without caching.
SYNC_POLICY=${SYNC_POLICY:-"on_demand"}

# Polling settings for sync tasks
INTERVAL_SECONDS=${INTERVAL_SECONDS:-15}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-7200}

# Config file listing upstream repos to mirror. Override via CONFIG_FILE env var.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=${CONFIG_FILE:-"${SCRIPT_DIR}/../configs/upstream-repos.yaml"}

# ── Load repo list from YAML config ──────────────────────────────────────────
# Parses configs/upstream-repos.yaml using python3 (available via pulp-cli's
# dependencies) and populates the RPM and DEB repo arrays.
load_repos_from_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: config file not found: $CONFIG_FILE" >&2
        exit 1
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] && UPSTREAM_RPM_REPOS+=("$line")
    done < <(python3 - "$CONFIG_FILE" <<'EOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
for r in data.get('rpm', []):
    print('{distro}|{version}|{component}|{arch}|{url}'.format(**r))
EOF
)

    while IFS= read -r line; do
        [[ -n "$line" ]] && UPSTREAM_DEB_REPOS+=("$line")
    done < <(python3 - "$CONFIG_FILE" <<'EOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
for r in data.get('deb', []):
    print('{distro}|{version}|{arch}|{url}|{distributions}|{components}'.format(**r))
EOF
)
}

declare -a UPSTREAM_RPM_REPOS=()
declare -a UPSTREAM_DEB_REPOS=()

# ── Filter state (populated by parse_args) ────────────────────────────────────
FILTER_DISTROS=()
FILTER_VERSIONS=()
FILTER_COMPONENTS=()
FILTER_ARCHS=()
DRY_RUN=false

show_help() {
    cat <<EOF
Usage: sync-upstream-repos.sh [OPTIONS]

Mirror upstream OS package repositories into Pulp. For each configured
upstream repo, this script:
  1. Creates a Pulp repository (if not already present)
  2. Creates or updates a Pulp remote (policy: \$SYNC_POLICY)
  3. Triggers a repository sync and waits for it to finish
  4. Creates a publication and distribution for internal consumption

Options:
    --distro LIST      Comma-separated distros to sync (default: all)
                       Supported: rocky, centos, epel, ubuntu
    --version LIST     Comma-separated distro versions (default: all)
                       e.g. 9,10,jammy,noble
    --component LIST   Comma-separated repo components (default: all)
                       e.g. baseos,appstream,everything
    --arch LIST        Comma-separated architectures (default: all)
                       e.g. x86_64,aarch64,amd64,arm64
    --dry-run          Print what would be done without making any changes
    -h, --help         Show this help and exit

Environment variables:
    SYNC_POLICY        Remote download policy (default: on_demand)
                       Values: on_demand | immediate | streamed
    INTERVAL_SECONDS   Seconds between sync task polls (default: 15)
    TIMEOUT_SECONDS    Max seconds to wait for a sync task (default: 7200)

Examples:
    # Mirror all configured upstream repos
    ./sync-upstream-repos.sh

    # Mirror only Rocky 9 repos
    ./sync-upstream-repos.sh --distro rocky --version 9

    # Mirror Ubuntu repos for x86_64 only, dry run
    ./sync-upstream-repos.sh --distro ubuntu --arch amd64 --dry-run

    # Mirror all RPM repos and force immediate download
    SYNC_POLICY=immediate ./sync-upstream-repos.sh --distro rocky,centos,epel
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --distro)
                [[ $# -lt 2 ]] && { echo "Error: --distro requires a value" >&2; exit 1; }
                IFS=',' read -ra FILTER_DISTROS <<< "$2"
                shift 2
                ;;
            --version)
                [[ $# -lt 2 ]] && { echo "Error: --version requires a value" >&2; exit 1; }
                IFS=',' read -ra FILTER_VERSIONS <<< "$2"
                shift 2
                ;;
            --component)
                [[ $# -lt 2 ]] && { echo "Error: --component requires a value" >&2; exit 1; }
                IFS=',' read -ra FILTER_COMPONENTS <<< "$2"
                shift 2
                ;;
            --arch)
                [[ $# -lt 2 ]] && { echo "Error: --arch requires a value" >&2; exit 1; }
                IFS=',' read -ra FILTER_ARCHS <<< "$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
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

# Return 0 if value is in the filter list, or if no filter is set.
matches_filter() {
    local value="$1"
    shift
    local -a filter=("$@")
    [[ ${#filter[@]} -eq 0 ]] && return 0
    local f
    for f in "${filter[@]}"; do
        [[ "$f" == "$value" ]] && return 0
    done
    return 1
}

# ── Pulp task polling ─────────────────────────────────────────────────────────

poll_until_task_done() {
    local task_href="$1"
    local deadline=""
    [[ -n "$TIMEOUT_SECONDS" ]] && deadline=$((SECONDS + TIMEOUT_SECONDS))

    local state
    while true; do
        state=$(LC_ALL=C pulp --format json task show --href "$task_href" | jq -r .state)
        case "$state" in
            completed)
                echo "    Sync task completed."
                return 0
                ;;
            failed|canceled)
                echo "Error: sync task ended with state: $state" >&2
                LC_ALL=C pulp --format json task show --href "$task_href" | jq .error >&2 || true
                return 1
                ;;
            waiting|running|canceling)
                echo "    Sync task state: $state – waiting ${INTERVAL_SECONDS}s ..."
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

# ── Core per-repo operations ──────────────────────────────────────────────────

ensure_repository() {
    local pkg_type="$1"
    local repo_name="$2"

    if pulp "$pkg_type" repository show --name "$repo_name" &>/dev/null; then
        echo "  Repository already exists: $repo_name"
        return 0
    fi

    echo "  Creating $pkg_type repository: $repo_name"
    local create_cmd="pulp $pkg_type repository create --name $repo_name"
    [[ "$pkg_type" == "rpm" ]] && create_cmd+=" --no-autopublish"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [dry-run] $create_cmd"
    else
        $create_cmd
    fi
}

ensure_remote_rpm() {
    local repo_name="$1"
    local remote_name="$2"
    local upstream_url="$3"

    if pulp rpm remote show --name "$remote_name" &>/dev/null; then
        echo "  Updating remote: $remote_name"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "    [dry-run] pulp rpm remote update --name $remote_name --url $upstream_url --policy $SYNC_POLICY"
        else
            pulp rpm remote update --name "$remote_name" --url "$upstream_url" \
                --policy "$SYNC_POLICY"
        fi
    else
        echo "  Creating remote: $remote_name"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "    [dry-run] pulp rpm remote create --name $remote_name --url $upstream_url --policy $SYNC_POLICY"
        else
            pulp rpm remote create --name "$remote_name" --url "$upstream_url" \
                --policy "$SYNC_POLICY"
        fi
    fi
}

ensure_remote_deb() {
    local remote_name="$1"
    local upstream_url="$2"
    local distributions="$3"
    local components="$4"

    if pulp deb remote show --name "$remote_name" &>/dev/null; then
        echo "  Updating remote: $remote_name"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "    [dry-run] pulp deb remote update --name $remote_name --url $upstream_url --distributions '$distributions' --components '$components' --policy $SYNC_POLICY"
        else
            pulp deb remote update --name "$remote_name" --url "$upstream_url" \
                --distributions "$distributions" --components "$components" \
                --policy "$SYNC_POLICY"
        fi
    else
        echo "  Creating remote: $remote_name"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "    [dry-run] pulp deb remote create --name $remote_name --url $upstream_url --distributions '$distributions' --components '$components' --policy $SYNC_POLICY"
        else
            pulp deb remote create --name "$remote_name" --url "$upstream_url" \
                --distributions "$distributions" --components "$components" \
                --policy "$SYNC_POLICY"
        fi
    fi
}

sync_repository() {
    local pkg_type="$1"
    local repo_name="$2"
    local remote_name="$3"

    echo "  Syncing repository: $repo_name (remote: $remote_name)"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [dry-run] pulp $pkg_type repository sync --name $repo_name --remote $remote_name"
        return 0
    fi

    local sync_out sync_exit=0
    sync_out=$(LC_ALL=C pulp -b --format json "$pkg_type" repository sync \
        --name "$repo_name" --remote "$remote_name" 2>&1) || sync_exit=$?

    if [[ "$sync_exit" -ne 0 ]]; then
        printf '%s\n' "$sync_out" >&2
        exit "$sync_exit"
    fi

    local task_href
    task_href=$(printf '%s\n' "$sync_out" \
        | sed -n 's/.*Started background task \(.*\)/\1/p' | tail -n1)
    if [[ -z "$task_href" ]]; then
        task_href=$(printf '%s\n' "$sync_out" \
            | jq -r 'if type == "object" then (.pulp_href // .task // empty) else empty end' \
            2>/dev/null | head -n1)
    fi
    if [[ -z "$task_href" ]]; then
        echo "Error: could not determine sync task href. Output:" >&2
        printf '%s\n' "$sync_out" >&2
        exit 1
    fi

    poll_until_task_done "$task_href"
}

ensure_publication_and_distribution() {
    local pkg_type="$1"
    local repo_name="$2"
    local dist_name="$3"
    local dist_base_path="$4"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [dry-run] pulp $pkg_type publication create --repository $repo_name"
        echo "    [dry-run] pulp $pkg_type distribution create/update --name $dist_name --base-path $dist_base_path"
        return 0
    fi

    echo "  Creating publication for: $repo_name"
    local pub_href
    pub_href=$(pulp "$pkg_type" publication create --repository "$repo_name" | jq -r '.pulp_href')

    echo "  Creating/updating distribution: $dist_name (base path: $dist_base_path)"
    if pulp "$pkg_type" distribution show --name "$dist_name" &>/dev/null; then
        pulp "$pkg_type" distribution update --name "$dist_name" --publication "$pub_href"
    else
        pulp "$pkg_type" distribution create \
            --name "$dist_name" \
            --base-path "$dist_base_path" \
            --publication "$pub_href"
    fi
    echo "  Distribution URL: ${PULP_SERVER_URL:-<PULP_SERVER_URL>}/pulp/content/$dist_base_path/"
}

# ── RPM repo pipeline ─────────────────────────────────────────────────────────

sync_upstream_rpm_repo() {
    local distro version component arch upstream_url
    IFS='|' read -r distro version component arch upstream_url <<< "$1"

    matches_filter "$distro"    "${FILTER_DISTROS[@]+"${FILTER_DISTROS[@]}"}"       || return 0
    matches_filter "$version"   "${FILTER_VERSIONS[@]+"${FILTER_VERSIONS[@]}"}"     || return 0
    matches_filter "$component" "${FILTER_COMPONENTS[@]+"${FILTER_COMPONENTS[@]}"}" || return 0
    matches_filter "$arch"      "${FILTER_ARCHS[@]+"${FILTER_ARCHS[@]}"}"           || return 0

    local repo_name="upstream-${distro}-${version}-${component}-${arch}"
    local remote_name="upstream-remote-${distro}-${version}-${component}-${arch}"
    local dist_name="upstream-dist-${distro}-${version}-${component}-${arch}"
    local dist_base_path="upstream/${distro}/${version}/${component}/${arch}"

    echo "── RPM: $repo_name"
    echo "   Upstream: $upstream_url"

    ensure_repository "rpm" "$repo_name"
    ensure_remote_rpm "$repo_name" "$remote_name" "$upstream_url"
    sync_repository "rpm" "$repo_name" "$remote_name"
    ensure_publication_and_distribution "rpm" "$repo_name" "$dist_name" "$dist_base_path"
    echo ""
}

# ── DEB repo pipeline ─────────────────────────────────────────────────────────

sync_upstream_deb_repo() {
    local distro version arch upstream_url distributions components
    IFS='|' read -r distro version arch upstream_url distributions components <<< "$1"

    matches_filter "$distro"  "${FILTER_DISTROS[@]+"${FILTER_DISTROS[@]}"}"   || return 0
    matches_filter "$version" "${FILTER_VERSIONS[@]+"${FILTER_VERSIONS[@]}"}" || return 0
    matches_filter "$arch"    "${FILTER_ARCHS[@]+"${FILTER_ARCHS[@]}"}"       || return 0

    local repo_name="upstream-${distro}-${version}-${arch}"
    local remote_name="upstream-remote-${distro}-${version}-${arch}"
    local dist_name="upstream-dist-${distro}-${version}-${arch}"
    local dist_base_path="upstream/${distro}/${version}/${arch}"

    echo "── DEB: $repo_name"
    echo "   Upstream: $upstream_url (suites: $distributions)"

    ensure_repository "deb" "$repo_name"
    ensure_remote_deb "$remote_name" "$upstream_url" "$distributions" "$components"
    sync_repository "deb" "$repo_name" "$remote_name"
    ensure_publication_and_distribution "deb" "$repo_name" "$dist_name" "$dist_base_path"
    echo ""
}

# ── Entry point ───────────────────────────────────────────────────────────────

parse_args "$@"
load_repos_from_config

if [[ "$DRY_RUN" == "true" ]]; then
    echo "Running in dry-run mode – no changes will be made."
    echo ""
fi

echo "Sync policy: $SYNC_POLICY"
echo "Started at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

failed=0

for entry in "${UPSTREAM_RPM_REPOS[@]}"; do
    sync_upstream_rpm_repo "$entry" || { echo "Error syncing: $entry" >&2; failed=$((failed + 1)); }
done

for entry in "${UPSTREAM_DEB_REPOS[@]}"; do
    sync_upstream_deb_repo "$entry" || { echo "Error syncing: $entry" >&2; failed=$((failed + 1)); }
done

echo "Finished at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ "$failed" -gt 0 ]]; then
    echo "Warning: $failed repo(s) failed to sync." >&2
    exit 1
fi

echo "All upstream repos synced successfully."
