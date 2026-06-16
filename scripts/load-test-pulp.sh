#!/bin/bash

# Benchmark Ceph package upload and download through Pulp the way CI does:
#   upload  — parallel full-package pulp-cli uploads
#   download — parallel containers run dnf/apt install cephadm from the Pulp distribution
#
# Upload fixtures (.rpm/.deb) must be supplied locally via --fixture-dir.

set -euo pipefail

PULP_SERVER_URL=${PULP_SERVER_URL:-""}
PULP_REPOSITORY=${PULP_REPOSITORY:-""}
PULP_DISTRIBUTION=${PULP_DISTRIBUTION:-""}
CONTENT_URL=${CONTENT_URL:-""}
PKG_TYPE=${PKG_TYPE:-""}
OS_DISTRO=${OS_DISTRO:-"centos"}
OS_VERSION=${OS_VERSION:-"9"}
OS_ARCH=${OS_ARCH:-"x86_64"}
TEST_PACKAGE=${TEST_PACKAGE:-"cephadm"}
FIXTURE_DIR=${FIXTURE_DIR:-""}
CONTAINER_ENGINE=${CONTAINER_ENGINE:-"podman"}

CONCURRENCY=${CONCURRENCY:-5}
REQUESTS_PER_WORKER=${REQUESTS_PER_WORKER:-1}
MAX_LATENCY_SEC=${MAX_LATENCY_SEC:-120.0}
MAX_CONTAINER_TIME=${MAX_CONTAINER_TIME:-600}
OUTPUT_FORMAT=${OUTPUT_FORMAT:-"table"}
SCENARIO=${SCENARIO:-"all"}

show_help() {
    cat <<EOF
Usage: load-test-pulp.sh [OPTIONS]

Benchmark full Ceph package upload (pulp-cli) and download (container install)
against Pulp. One pulp/install command per request; reports latency and MiB moved.

Options:
    --server-url URL         Pulp base URL (default: \$PULP_SERVER_URL)
    --scenario NAME          all | ceph_upload | ceph_download | ceph_mixed (default: all)
    --concurrency N          Parallel workers/containers (default: 5)
    --requests N             Commands per worker (default: 1)
    --repository NAME        Pulp repository for uploads (required for upload/mixed)
    --distribution NAME      Pulp distribution for download lookup (or use --content-url)
    --content-url URL        Pulp content base URL for download (skips distribution lookup)
    --pkg-type TYPE          rpm | deb (default: infer from fixture extension)
    --distro NAME            Container OS: centos | rocky | ubuntu (default: centos)
    --distro-version VER     Container OS version, e.g. 9, jammy (default: 9)
    --arch ARCH              Container arch: x86_64 | arm64 (default: x86_64)
    --package NAME           Package to install for download probe (default: cephadm)
    --fixture-dir PATH       Local .rpm/.deb directory (required for upload/mixed)
    --container-engine CMD   podman | docker (default: podman)
    --max-latency SEC        p95 threshold seconds (default: 120)
    --max-container-time SEC Timeout per container install (default: 600)
    --format FORMAT          table | csv | json (default: table)
    -h, --help               Show help

Environment:
    PULP_SERVER_URL, PULP_USERNAME, PULP_PASSWORD (required)
    PULP_REPOSITORY, PULP_DISTRIBUTION, CONTENT_URL (optional if passed as flags)

Examples:

    ./load-test-pulp.sh --scenario ceph_download \\
        --distribution dist-main-centos-9-x86_64-a12a619b \\
        --concurrency 5

    ./load-test-pulp.sh --scenario ceph_upload \\
        --repository ceph-main-centos-9-x86_64 \\
        --fixture-dir ~/ceph-rpms --concurrency 10
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server-url) PULP_SERVER_URL="$2"; shift 2 ;;
            --scenario) SCENARIO="$2"; shift 2 ;;
            --concurrency) CONCURRENCY="$2"; shift 2 ;;
            --requests) REQUESTS_PER_WORKER="$2"; shift 2 ;;
            --repository) PULP_REPOSITORY="$2"; shift 2 ;;
            --distribution) PULP_DISTRIBUTION="$2"; shift 2 ;;
            --content-url) CONTENT_URL="$2"; shift 2 ;;
            --pkg-type) PKG_TYPE="$2"; shift 2 ;;
            --distro) OS_DISTRO="$2"; shift 2 ;;
            --distro-version) OS_VERSION="$2"; shift 2 ;;
            --arch) OS_ARCH="$2"; shift 2 ;;
            --package) TEST_PACKAGE="$2"; shift 2 ;;
            --fixture-dir) FIXTURE_DIR="$2"; shift 2 ;;
            --container-engine) CONTAINER_ENGINE="$2"; shift 2 ;;
            --max-latency) MAX_LATENCY_SEC="$2"; shift 2 ;;
            --max-container-time) MAX_CONTAINER_TIME="$2"; shift 2 ;;
            --format) OUTPUT_FORMAT="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) echo "Error: unknown option '$1'" >&2; exit 1 ;;
        esac
    done
}

require_cmd() {
    command -v "$1" &>/dev/null || {
        echo "Error: '$1' is required but not found in PATH" >&2; exit 1; }
}

require_auth() {
    [[ -n "${PULP_USERNAME:-}" && -n "${PULP_PASSWORD:-}" ]] || {
        echo "Error: PULP_USERNAME and PULP_PASSWORD are required." >&2; exit 1; }
}

pulp_cmd() {
    local args=(--format json --no-verify-ssl)
    [[ -n "$PULP_SERVER_URL" ]] && args+=(--base-url "$PULP_SERVER_URL")
    args+=(--username "$PULP_USERNAME" --password "$PULP_PASSWORD")
    LC_ALL=C pulp "${args[@]}" "$@"
}

resolve_pkg_type() {
    if [[ -n "$PKG_TYPE" ]]; then
        case "$PKG_TYPE" in
            rpm|deb) echo "$PKG_TYPE"; return ;;
            *) echo "Error: --pkg-type must be rpm or deb" >&2; exit 1 ;;
        esac
    fi
    case "$OS_DISTRO" in
        ubuntu) echo deb ;;
        centos|rocky) echo rpm ;;
        *) echo "Error: unsupported --distro '$OS_DISTRO' (use --pkg-type)" >&2; exit 1 ;;
    esac
}

infer_pkg_type_from_fixtures() {
    local f ext
    for f in "${FIXTURE_FILES[@]}"; do
        ext="${f##*.}"
        case "$ext" in
            rpm) echo rpm; return ;;
            deb) echo deb; return ;;
        esac
    done
    echo "Error: could not infer pkg type from fixtures; pass --pkg-type" >&2
    exit 1
}

upload_pkg_type() {
    if [[ -n "$PKG_TYPE" ]]; then
        resolve_pkg_type
    else
        infer_pkg_type_from_fixtures
    fi
}

require_repository() {
    [[ -n "$PULP_REPOSITORY" ]] || {
        echo "Error: --repository is required for upload scenarios." >&2
        exit 1
    }
}

verify_upload_repository() {
    local pkg_type
    pkg_type=$(upload_pkg_type)
    if pulp_cmd "$pkg_type" repository show --name "$PULP_REPOSITORY" >/dev/null 2>&1; then
        return 0
    fi
    echo "Error: Pulp $pkg_type repository '$PULP_REPOSITORY' not found." >&2
    echo "List existing repos, e.g.:" >&2
    echo "  pulp --base-url \"\$PULP_SERVER_URL\" rpm repository list --limit 20" >&2
    echo "Create the repo first (see configs/repos.yaml + create-repos.sh), or pick an existing name." >&2
    exit 1
}

resolve_pulp_content_base() {
    if [[ -n "$CONTENT_URL" ]]; then
        echo "${CONTENT_URL%/}/"
        return
    fi

    [[ -n "$PULP_DISTRIBUTION" ]] || {
        echo "Error: pass --distribution or --content-url for download scenarios." >&2
        exit 1
    }

    local pkg_type dist_name json base_url
    for pkg_type in rpm deb; do
        if json=$(pulp_cmd "$pkg_type" distribution show --name "$PULP_DISTRIBUTION" 2>/dev/null); then
            base_url=$(printf '%s\n' "$json" | jq -r '.base_url // empty')
            [[ -n "$base_url" ]] && { echo "${base_url%/}/"; return; }
        fi
    done

    echo "Error: Pulp distribution '$PULP_DISTRIBUTION' not found (tried rpm and deb)." >&2
    exit 1
}

container_image() {
    case "$OS_DISTRO" in
        centos) echo "quay.io/centos/centos:stream${OS_VERSION}" ;;
        rocky)  echo "rockylinux:${OS_VERSION}" ;;
        ubuntu)
            case "$OS_VERSION" in
                jammy) echo "ubuntu:jammy" ;;
                noble) echo "ubuntu:noble" ;;
                *) echo "ubuntu:${OS_VERSION}" ;;
            esac
            ;;
        *) echo "Error: unsupported --distro '$OS_DISTRO' for container image" >&2; exit 1 ;;
    esac
}

container_platform() {
    case "$OS_ARCH" in
        x86_64) echo "linux/amd64" ;;
        aarch64|arm64) echo "linux/arm64" ;;
        *) echo "" ;;
    esac
}

require_fixture_dir() {
    [[ -n "$FIXTURE_DIR" ]] || {
        echo "Error: --fixture-dir is required for upload scenarios (download RPMs/debs locally first)." >&2
        exit 1
    }
    [[ -d "$FIXTURE_DIR" ]] || {
        echo "Error: fixture dir not found: $FIXTURE_DIR" >&2
        exit 1
    }
}

collect_fixture_files() {
    FIXTURE_FILES=()
    while IFS= read -r -d '' f; do
        FIXTURE_FILES+=("$f")
    done < <(find "$FIXTURE_DIR" -type f \( -name '*.rpm' -o -name '*.deb' \) -print0 | sort -z)
    [[ ${#FIXTURE_FILES[@]} -gt 0 ]] || {
        echo "Error: no .rpm/.deb files in $FIXTURE_DIR" >&2; exit 1; }
}

run_single_upload() {
    local file="$1"
    local pkg_type bytes start end elapsed

    pkg_type=$(upload_pkg_type)
    bytes=$(wc -c < "$file" | tr -d ' ')
    start=$(date +%s.%N)
    if pulp_cmd "$pkg_type" content -t package upload --repository "$PULP_REPOSITORY" --file "$file" >/dev/null 2>&1; then
        end=$(date +%s.%N)
        elapsed=$(awk "BEGIN { printf \"%.6f\", $end - $start }")
        echo "200 $elapsed $bytes"
    else
        end=$(date +%s.%N)
        elapsed=$(awk "BEGIN { printf \"%.6f\", $end - $start }")
        echo "000 $elapsed $bytes"
    fi
}

upload_worker_loop() {
    local out_file="$1"
    local i idx file

    : > "$out_file"
    for (( i=0; i<REQUESTS_PER_WORKER; i++ )); do
        idx=$(( (i + RANDOM) % ${#FIXTURE_FILES[@]} ))
        file="${FIXTURE_FILES[$idx]}"
        run_single_upload "$file" >> "$out_file"
        echo >> "$out_file"
    done
}

run_upload_scenario() {
    local name="$1"
    local tmpdir start_ts end_ts
    local pids=() w

    tmpdir=$(mktemp -d)
    start_ts=$(date +%s.%N)
    for (( w=0; w<CONCURRENCY; w++ )); do
        upload_worker_loop "$tmpdir/worker_${w}.log" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    end_ts=$(date +%s.%N)

    SCENARIO_NAME="$name"
    SCENARIO_URL="pulp $(upload_pkg_type) content upload -> ${PULP_REPOSITORY}"
    SCENARIO_DURATION_SEC=$(awk "BEGIN { printf \"%.3f\", $end_ts - $start_ts }")
    compute_stats "$tmpdir"
    rm -rf "$tmpdir"
}

rpm_noarch_base_url() {
    local base_url="$1"
    if [[ "$base_url" == */x86_64/ ]]; then
        echo "${base_url%/x86_64/}/noarch/"
    elif [[ "$base_url" == */aarch64/ ]]; then
        echo "${base_url%/aarch64/}/noarch/"
    else
        echo ""
    fi
}

probe_download_container() {
    local base_url="$1"
    local image platform run_args inner logfile noarch_url

    image=$(container_image)
    platform=$(container_platform)
    logfile=$(mktemp)
    run_args=(run --rm --network host)
    [[ -n "$platform" ]] && run_args+=(--platform "$platform")
    noarch_url=$(rpm_noarch_base_url "$base_url")

    if [[ "$(resolve_pkg_type)" == rpm ]]; then
        inner=$(cat <<INNER
set -eu
cat > /etc/yum.repos.d/ceph.repo <<REPO
[ceph]
name=Ceph Pulp x86_64
baseurl=${base_url}
enabled=1
gpgcheck=0
sslverify=0
REPO
if [[ -n "${noarch_url}" ]]; then
cat >> /etc/yum.repos.d/ceph.repo <<REPO

[ceph-noarch]
name=Ceph Pulp noarch
baseurl=${noarch_url}
enabled=1
gpgcheck=0
sslverify=0
REPO
fi
if command -v dnf >/dev/null 2>&1; then M=dnf; else M=yum; fi
\$M clean all >/dev/null 2>&1 || true
CEPH_REPOS=ceph
grep -q '^\[ceph-noarch\]' /etc/yum.repos.d/ceph.repo && CEPH_REPOS=ceph,ceph-noarch
START=\$(date +%s.%N)
if ! \$M install -y --enablerepo=\${CEPH_REPOS} --setopt=metadata_expire=0 ${TEST_PACKAGE} 2>&1 | tee /tmp/ceph-install.log; then
  echo "INSTALL_FAILED=1" >&2
  exit 1
fi
END=\$(date +%s.%N)
BYTES=\$(grep -iE 'Total download size:|Total size of inbound packages:' /tmp/ceph-install.log | tail -1 | sed -E 's/.*(Total download size:|Total size of inbound packages:)[[:space:]]*//')
if [[ -z "\${BYTES}" ]]; then
  BYTES=\$(grep -iE '^Downloaded:' /tmp/ceph-install.log | awk '{print \$2, \$3}' | tail -1)
fi
echo "ELAPSED_SEC=\$(awk "BEGIN { printf \"%.6f\", \$END - \$START }")"
echo "BYTES_RAW=\${BYTES:-0}"
INNER
)
    else
        inner=$(cat <<INNER
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "deb [trusted=yes] ${base_url} ./" > /etc/apt/sources.list.d/ceph.list
apt-get update -qq 2>&1 | tee /tmp/ceph-install.log
START=\$(date +%s.%N)
apt-get install -y --no-install-recommends ${TEST_PACKAGE} 2>&1 | tee -a /tmp/ceph-install.log
END=\$(date +%s.%N)
BYTES=\$(grep -E '^(Need to get|Fetched)' /tmp/ceph-install.log | tail -1 | grep -oE '[0-9]+ [kMG]B' | tail -1 || true)
echo "ELAPSED_SEC=\$(awk "BEGIN { printf \"%.6f\", \$END - \$START }")"
echo "BYTES_RAW=\${BYTES:-0}"
INNER
)
    fi

    if ! run_with_timeout "$MAX_CONTAINER_TIME" "$CONTAINER_ENGINE" "${run_args[@]}" "$image" bash -c "$inner" \
        > "$logfile" 2>&1; then
        rm -f "$logfile"
        echo "000 0 0"
        return
    fi

    local elapsed raw_bytes bytes
    elapsed=$(grep '^ELAPSED_SEC=' "$logfile" | tail -1 | cut -d= -f2-)
    raw_bytes=$(grep '^BYTES_RAW=' "$logfile" | tail -1 | cut -d= -f2-)
    rm -f "$logfile"
    bytes=$(size_to_bytes "$raw_bytes")
    [[ -z "$elapsed" ]] && { echo "000 0 0"; return; }
    [[ "$bytes" -eq 0 ]] && bytes=1
    echo "200 $elapsed $bytes"
}

size_to_bytes() {
    local raw="$1" num unit
    raw="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/mib/mi/g; s/kib/ki/g; s/gib/gi/g')"
    read -r num unit <<< "$raw"
    [[ -z "$num" ]] && { echo 0; return; }
    case "$unit" in
        k|kb|ki) awk "BEGIN { printf \"%.0f\", $num * 1024 }" ;;
        m|mb|mi) awk "BEGIN { printf \"%.0f\", $num * 1048576 }" ;;
        g|gb|gi) awk "BEGIN { printf \"%.0f\", $num * 1073741824 }" ;;
        *) echo "$num" ;;
    esac
}

run_with_timeout() {
    local limit="$1"
    shift
    if command -v timeout &>/dev/null; then
        timeout "$limit" "$@"
        return
    fi
    "$@" &
    local cmd_pid=$! watcher_pid
    ( sleep "$limit"; kill "$cmd_pid" 2>/dev/null ) &
    watcher_pid=$!
    if wait "$cmd_pid" 2>/dev/null; then
        kill "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
        return 0
    fi
    kill "$watcher_pid" 2>/dev/null; wait "$watcher_pid" 2>/dev/null
    return 124
}

download_worker_loop() {
    local base_url="$1"
    local out_file="$2"
    local i

    : > "$out_file"
    for (( i=0; i<REQUESTS_PER_WORKER; i++ )); do
        probe_download_container "$base_url" >> "$out_file"
        echo >> "$out_file"
    done
}

run_download_scenario() {
    local name="$1" base_url="$2"
    local tmpdir start_ts end_ts
    local pids=() w

    tmpdir=$(mktemp -d)
    start_ts=$(date +%s.%N)
    for (( w=0; w<CONCURRENCY; w++ )); do
        download_worker_loop "$base_url" "$tmpdir/worker_${w}.log" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    end_ts=$(date +%s.%N)

    SCENARIO_NAME="$name"
    SCENARIO_URL="container ${TEST_PACKAGE} install from ${base_url}"
    SCENARIO_DURATION_SEC=$(awk "BEGIN { printf \"%.3f\", $end_ts - $start_ts }")
    compute_stats "$tmpdir"
    rm -rf "$tmpdir"
}

save_scenario_stats() {
    local file="$1"
    {
        printf '%s\n' "$SCENARIO_NAME" "$SCENARIO_URL" "$STAT_COUNT" "$STAT_ERRORS"
        printf '%s\n' "$STAT_TOTAL_MIB" "$STAT_P50" "$STAT_P95" "$STAT_P99" "$STAT_MAX"
        printf '%s\n' "$STAT_MIBPS" "$STAT_STATUS"
    } > "$file"
}

load_scenario_stats() {
    local file="$1"
    {
        IFS= read -r SCENARIO_NAME
        IFS= read -r SCENARIO_URL
        IFS= read -r STAT_COUNT
        IFS= read -r STAT_ERRORS
        IFS= read -r STAT_TOTAL_MIB
        IFS= read -r STAT_P50
        IFS= read -r STAT_P95
        IFS= read -r STAT_P99
        IFS= read -r STAT_MAX
        IFS= read -r STAT_MIBPS
        IFS= read -r STAT_STATUS
    } < "$file"
}

run_mixed_scenario() {
    local base_url="$1"
    local read_c write_c read_stats write_stats

    read_c=$(( CONCURRENCY / 2 )); [[ "$read_c" -lt 1 ]] && read_c=1
    write_c=$(( CONCURRENCY - read_c )); [[ "$write_c" -lt 1 ]] && write_c=1

    read_stats=$(mktemp); write_stats=$(mktemp)
    echo "Mixed load: ${read_c} container install workers + ${write_c} upload workers (parallel) ..."
    echo ""

    (
        CONCURRENCY=$read_c
        run_download_scenario "ceph_mixed_download" "$base_url"
        save_scenario_stats "$read_stats"
    ) &
    local dl_pid=$!

    (
        CONCURRENCY=$write_c
        run_upload_scenario "ceph_mixed_upload"
        save_scenario_stats "$write_stats"
    ) &
    local up_pid=$!

    wait "$dl_pid" || true
    wait "$up_pid" || true

    load_scenario_stats "$read_stats"; record_scenario_result
    load_scenario_stats "$write_stats"; record_scenario_result
    rm -f "$read_stats" "$write_stats"
}

compute_stats() {
    local tmpdir="$1"
    local times_file errors_file bytes_file total_bytes
    times_file=$(mktemp); errors_file=$(mktemp); bytes_file=$(mktemp)
    total_bytes=0

    local f code t b
    for f in "$tmpdir"/worker_*.log; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            read -r code t b <<< "$line"
            if [[ "$code" =~ ^(200|206)$ ]]; then
                echo "$t" >> "$times_file"
                echo "$b" >> "$bytes_file"
                total_bytes=$(( total_bytes + b ))
            else
                echo "$code" >> "$errors_file"
            fi
        done < "$f"
    done

    local total err_count
    total=$(wc -l < "$times_file" | tr -d ' ')
    err_count=$(wc -l < "$errors_file" | tr -d ' ')

    STAT_TOTAL_MIB=$(awk "BEGIN { printf \"%.2f\", $total_bytes / 1048576 }")
    if [[ "$total" -eq 0 ]]; then
        STAT_COUNT=0; STAT_ERRORS="$err_count"
        STAT_P50="-"; STAT_P95="-"; STAT_P99="-"; STAT_MAX="-"; STAT_MIBPS="-"
        STAT_STATUS="FAIL (no successful operations)"
        rm -f "$times_file" "$errors_file" "$bytes_file"
        return
    fi

    read -r STAT_P50 STAT_P95 STAT_P99 STAT_MAX avg_t <<EOF
$(sort -n "$times_file" | awk '
    function pct(n,p, i){ i=int(n*p); if(i<1)i=1; if(i>n)i=n; return i }
    { a[NR]=$1; sum+=$1 }
    END {
        n=NR
        printf "%.3f %.3f %.3f %.3f %.3f\n", a[pct(n,0.50)], a[pct(n,0.95)], a[pct(n,0.99)], a[n], sum/n
    }')
EOF

    STAT_COUNT=$total
    STAT_ERRORS="$err_count"
    STAT_MIBPS=$(awk "BEGIN { printf \"%.2f\", ($total_bytes / 1048576) / ($SCENARIO_DURATION_SEC > 0 ? $SCENARIO_DURATION_SEC : 1) }")

    if awk "BEGIN { exit !($STAT_P95 > $MAX_LATENCY_SEC) }"; then
        STAT_STATUS="FAIL (p95 ${STAT_P95}s > ${MAX_LATENCY_SEC}s)"
    elif [[ "$err_count" -gt 0 ]]; then
        STAT_STATUS="FAIL (${err_count} errors)"
    else
        STAT_STATUS="PASS"
    fi
    rm -f "$times_file" "$errors_file" "$bytes_file"
}

declare -a RESULT_NAMES=() RESULT_URLS=() RESULT_COUNTS=() RESULT_ERRORS=()
declare -a RESULT_MIB=() RESULT_P50=() RESULT_P95=() RESULT_P99=() RESULT_MAX=()
declare -a RESULT_MIBPS=() RESULT_STATUS=()

record_scenario_result() {
    RESULT_NAMES+=("$SCENARIO_NAME")
    RESULT_URLS+=("$SCENARIO_URL")
    RESULT_COUNTS+=("$STAT_COUNT")
    RESULT_ERRORS+=("$STAT_ERRORS")
    RESULT_MIB+=("$STAT_TOTAL_MIB")
    RESULT_P50+=("$STAT_P50")
    RESULT_P95+=("$STAT_P95")
    RESULT_P99+=("$STAT_P99")
    RESULT_MAX+=("$STAT_MAX")
    RESULT_MIBPS+=("$STAT_MIBPS")
    RESULT_STATUS+=("$STAT_STATUS")
}

print_table() {
    printf '%-22s  %6s  %8s  %8s  %8s  %8s  %8s  %7s  %s\n' \
        "Scenario" "Count" "MiB" "p50(s)" "p95(s)" "p99(s)" "max(s)" "MiB/s" "Status"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    local i
    for (( i=0; i<${#RESULT_NAMES[@]}; i++ )); do
        printf '%-22s  %6s  %8s  %8s  %8s  %8s  %8s  %7s  %s\n' \
            "${RESULT_NAMES[$i]}" "${RESULT_COUNTS[$i]}" "${RESULT_MIB[$i]}" \
            "${RESULT_P50[$i]}" "${RESULT_P95[$i]}" "${RESULT_P99[$i]}" "${RESULT_MAX[$i]}" \
            "${RESULT_MIBPS[$i]}" "${RESULT_STATUS[$i]}"
    done
}

print_csv() {
    echo "scenario,url,count,errors,total_mib,p50_s,p95_s,p99_s,max_s,mib_per_s,status"
    local i
    for (( i=0; i<${#RESULT_NAMES[@]}; i++ )); do
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "${RESULT_NAMES[$i]}" "${RESULT_URLS[$i]}" "${RESULT_COUNTS[$i]}" "${RESULT_ERRORS[$i]}" \
            "${RESULT_MIB[$i]}" "${RESULT_P50[$i]}" "${RESULT_P95[$i]}" "${RESULT_P99[$i]}" \
            "${RESULT_MAX[$i]}" "${RESULT_MIBPS[$i]}" "${RESULT_STATUS[$i]}"
    done
}

print_json() {
    echo "["
    local i last=$(( ${#RESULT_NAMES[@]} - 1 ))
    for (( i=0; i<${#RESULT_NAMES[@]}; i++ )); do
        local comma=","; [[ "$i" -eq "$last" ]] && comma=""
        printf '  {"scenario":"%s","url":"%s","count":%s,"errors":%s,"total_mib":"%s","p50_s":"%s","p95_s":"%s","p99_s":"%s","max_s":"%s","mib_per_s":"%s","status":"%s"}%s\n' \
            "${RESULT_NAMES[$i]}" "${RESULT_URLS[$i]}" "${RESULT_COUNTS[$i]}" "${RESULT_ERRORS[$i]}" \
            "${RESULT_MIB[$i]}" "${RESULT_P50[$i]}" "${RESULT_P95[$i]}" "${RESULT_P99[$i]}" \
            "${RESULT_MAX[$i]}" "${RESULT_MIBPS[$i]}" "${RESULT_STATUS[$i]}" "$comma"
    done
    echo "]"
}

# ── Main ──────────────────────────────────────────────────────────────────────
parse_args "$@"

require_cmd jq
require_cmd awk
require_cmd sort
require_auth
require_cmd pulp

case "$SCENARIO" in
    all|ceph_upload|ceph_download|ceph_mixed) ;;
    *) echo "Error: --scenario must be all, ceph_upload, ceph_download, or ceph_mixed" >&2; exit 1 ;;
esac

[[ -n "$PULP_SERVER_URL" ]] || { echo "Error: set PULP_SERVER_URL or --server-url" >&2; exit 1; }

needs_upload=false
needs_download=false
case "$SCENARIO" in
    all) needs_upload=true; needs_download=true ;;
    ceph_upload) needs_upload=true ;;
    ceph_download) needs_download=true ;;
    ceph_mixed) needs_upload=true; needs_download=true ;;
esac

echo "Pulp server:        $PULP_SERVER_URL"
[[ -n "$PULP_REPOSITORY" ]] && echo "Repository:         $PULP_REPOSITORY"
[[ -n "$PULP_DISTRIBUTION" ]] && echo "Distribution:       $PULP_DISTRIBUTION"
[[ -n "$CONTENT_URL" ]] && echo "Content URL:        $CONTENT_URL"
echo "Container OS:       $OS_DISTRO/$OS_VERSION ($OS_ARCH)"
echo "Download package:   $TEST_PACKAGE"
echo "Concurrency:        $CONCURRENCY"
echo "Requests per worker: $REQUESTS_PER_WORKER"
echo "Scenario:           $SCENARIO"
echo "Run time:           $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

if [[ "$needs_upload" == "true" ]]; then
    require_repository
    require_fixture_dir
    collect_fixture_files
    verify_upload_repository
    echo "Upload fixtures:    $FIXTURE_DIR (${#FIXTURE_FILES[@]} package(s))"
    echo ""
fi

if [[ "$needs_download" == "true" ]]; then
    PULP_CONTENT_BASE=$(resolve_pulp_content_base)
    echo "Pulp content base:  $PULP_CONTENT_BASE"
    echo ""
fi

if [[ "$SCENARIO" == "all" || "$SCENARIO" == "ceph_upload" ]]; then
    echo "=== Ceph upload load (full packages, one pulp-cli command per request) ==="
    run_upload_scenario "ceph_upload"
    record_scenario_result
    echo ""
fi

if [[ "$SCENARIO" == "all" || "$SCENARIO" == "ceph_download" ]]; then
    require_cmd "$CONTAINER_ENGINE"
    echo "=== Ceph download load (${CONCURRENCY} containers, dnf/apt install ${TEST_PACKAGE}) ==="
    run_download_scenario "ceph_download" "$PULP_CONTENT_BASE"
    record_scenario_result
    echo ""
fi

if [[ "$SCENARIO" == "ceph_mixed" ]]; then
    require_cmd "$CONTAINER_ENGINE"
    echo "=== Ceph mixed load (parallel install + upload) ==="
    run_mixed_scenario "$PULP_CONTENT_BASE"
    echo ""
fi

pass_count=0; fail_count=0
for status in "${RESULT_STATUS[@]}"; do
    case "$status" in PASS) pass_count=$((pass_count+1)) ;; FAIL*) fail_count=$((fail_count+1)) ;; esac
done

echo "── Results ──────────────────────────────────────────────────────────────────────"
case "$OUTPUT_FORMAT" in
    csv) print_csv ;;
    json) print_json ;;
    *) print_table ;;
esac
echo ""
echo "Summary: ${pass_count} PASS  |  ${fail_count} FAIL  |  ${#RESULT_STATUS[@]} scenario(s)"
echo "Use MiB and MiB/s totals with p95 latency to size pulp-api/worker CPU and RAM."

[[ "$fail_count" -gt 0 ]] && exit 1
exit 0
