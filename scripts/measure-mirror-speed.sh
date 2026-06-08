#!/bin/bash

# Probes download and upload throughput against the Pulp content server in parallel
# and reports MiB/s with pass/fail status against a configurable speed threshold.
#
# Run from an OCP node or via `oc exec` inside a pod to simulate real client
# network conditions.

set -euo pipefail

PULP_SERVER_URL=${PULP_SERVER_URL:-""}
PROBE_BYTES=${PROBE_BYTES:-10485760}    # bytes to download per probe (default 10 MiB)
UPLOAD_BYTES=${UPLOAD_BYTES:-10485760}  # bytes to upload for the upload probe (default 10 MiB)
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-10}  # curl connect timeout in seconds
MAX_TIME=${MAX_TIME:-120}               # curl max total time per probe in seconds
OUTPUT_FORMAT=${OUTPUT_FORMAT:-"table"} # table | csv | json
MIN_SPEED=${MIN_SPEED:-0}              # MiB/s threshold for PASS/FAIL (0 = no threshold)
FULL_PACKAGE=${FULL_PACKAGE:-false}    # download an actual .rpm/.deb instead of metadata

show_help() {
    cat <<EOF
Usage: measure-mirror-speed.sh [OPTIONS]

Probe download and upload throughput against the Pulp content server in parallel
and report MiB/s with pass/fail status.

Options:
    --server-url URL    Pulp server URL (default: \$PULP_SERVER_URL)
    --bytes N           Bytes to download per probe (default: 10485760 = 10 MiB)
    --upload-bytes N    Bytes to upload for the upload probe (default: 10485760 = 10 MiB)
    --timeout N         curl connect timeout in seconds (default: 10)
    --max-time N        curl total time limit per probe in seconds (default: 120)
    --min-speed N       Minimum MiB/s to mark a probe as PASS (default: 0 = disabled)
    --format FORMAT     Output format: table | csv | json (default: table)
    --distro LIST       Comma-separated distros to probe (default: all)
                        e.g. rocky,centos,ubuntu
    --compare URL       Also probe this upstream URL and compare speeds
    --skip-upload       Skip the upload speed probe
    --full-package      Download an actual .rpm/.deb package instead of repo metadata
                        (slower but most accurate measure of real package download speed)
    -h, --help          Show this help and exit

Environment variables:
    PULP_SERVER_URL     Pulp server base URL (required if --server-url not set)
    PULP_USERNAME       Username for Pulp content server (optional)
    PULP_PASSWORD       Password for Pulp content server (optional)
    MIN_SPEED           Minimum MiB/s threshold (overridden by --min-speed)

Examples:
    # Probe all mirrors + upload speed
    export PULP_SERVER_URL=https://pulp.internal.example.com
    ./measure-mirror-speed.sh

    # Download only, Rocky mirrors, fail if below 10 MiB/s
    ./measure-mirror-speed.sh --distro rocky --min-speed 10 --skip-upload

    # Run from inside an OCP pod
    oc exec -n <namespace> <pod-name> -- bash -s < ./measure-mirror-speed.sh
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
FILTER_DISTROS=()
COMPARE_URL=""
SKIP_UPLOAD=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server-url)
                [[ $# -lt 2 ]] && { echo "Error: --server-url requires a value" >&2; exit 1; }
                PULP_SERVER_URL="$2"; shift 2 ;;
            --bytes)
                [[ $# -lt 2 ]] && { echo "Error: --bytes requires a value" >&2; exit 1; }
                PROBE_BYTES="$2"; shift 2 ;;
            --upload-bytes)
                [[ $# -lt 2 ]] && { echo "Error: --upload-bytes requires a value" >&2; exit 1; }
                UPLOAD_BYTES="$2"; shift 2 ;;
            --timeout)
                [[ $# -lt 2 ]] && { echo "Error: --timeout requires a value" >&2; exit 1; }
                CONNECT_TIMEOUT="$2"; shift 2 ;;
            --max-time)
                [[ $# -lt 2 ]] && { echo "Error: --max-time requires a value" >&2; exit 1; }
                MAX_TIME="$2"; shift 2 ;;
            --min-speed)
                [[ $# -lt 2 ]] && { echo "Error: --min-speed requires a value" >&2; exit 1; }
                MIN_SPEED="$2"; shift 2 ;;
            --format)
                [[ $# -lt 2 ]] && { echo "Error: --format requires a value" >&2; exit 1; }
                OUTPUT_FORMAT="$2"; shift 2 ;;
            --distro)
                [[ $# -lt 2 ]] && { echo "Error: --distro requires a value" >&2; exit 1; }
                IFS=',' read -ra FILTER_DISTROS <<< "$2"; shift 2 ;;
            --compare)
                [[ $# -lt 2 ]] && { echo "Error: --compare requires a value" >&2; exit 1; }
                COMPARE_URL="$2"; shift 2 ;;
            --skip-upload) SKIP_UPLOAD=true; shift ;;
            --full-package) FULL_PACKAGE=true; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) echo "Error: unknown option '$1'" >&2; exit 1 ;;
        esac
    done
}

# ── Helpers ───────────────────────────────────────────────────────────────────
require_cmd() {
    command -v "$1" &>/dev/null || {
        echo "Error: '$1' is required but not found in PATH" >&2; exit 1; }
}

# Build curl auth args if credentials are set
curl_auth_args() {
    local args=()
    [[ -n "${PULP_USERNAME:-}" ]] && [[ -n "${PULP_PASSWORD:-}" ]] \
        && args=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")
    printf '%s\n' "${args[@]}"
}

# Probe a URL: download up to PROBE_BYTES bytes and return MiB/s
# Returns "error" if the download fails or times out.
probe_speed() {
    local url="$1"
    local auth_args=()
    [[ -n "${PULP_USERNAME:-}" ]] && [[ -n "${PULP_PASSWORD:-}" ]] \
        && auth_args=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")

    local result
    result=$(curl -sSL \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        --range "0-$((PROBE_BYTES - 1))" \
        -k \
        "${auth_args[@]}" \
        -o /dev/null \
        -w "%{speed_download} %{size_download} %{http_code} %{time_total}" \
        "$url" 2>/dev/null) || { echo "error"; return; }

    local speed_bps size_bytes http_code time_total
    read -r speed_bps size_bytes http_code time_total <<< "$result"

    if [[ "$http_code" != "200" ]] && [[ "$http_code" != "206" ]]; then
        echo "http_$http_code"
        return
    fi

    if [[ "$size_bytes" -eq 0 ]] 2>/dev/null; then
        echo "empty"
        return
    fi

    # Convert bytes/s to MiB/s, rounded to 2 decimal places
    local mibps
    mibps=$(awk "BEGIN { printf \"%.2f\", $speed_bps / 1048576 }")
    echo "$mibps"
}

# Probe upload speed using Pulp's chunked upload API:
#   1. POST /uploads/ with {"size": N} to create a session
#   2. PUT the payload as a single chunk with Content-Range
#   3. DELETE the session (no commit — we only measure throughput)
# Returns MiB/s or "error"/"http_NNN".
probe_upload_speed() {
    local api_url="${PULP_SERVER_URL%/}/pulp/api/v3/uploads/"
    local auth_args=()
    [[ -n "${PULP_USERNAME:-}" ]] && [[ -n "${PULP_PASSWORD:-}" ]] \
        && auth_args=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")

    # Step 1: create upload session
    local create_resp upload_href upload_url
    create_resp=$(curl -sSL -k \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "${auth_args[@]+"${auth_args[@]}"}" \
        -H "Content-Type: application/json" \
        -d "{\"size\": $UPLOAD_BYTES}" \
        "$api_url" 2>/dev/null) || { echo "error"; return; }

    upload_href=$(printf '%s\n' "$create_resp" | jq -r '.pulp_href // empty' 2>/dev/null)
    [[ -z "$upload_href" ]] && { echo "error"; return; }
    upload_url="${PULP_SERVER_URL%/}${upload_href}"

    # Step 2: write payload to a temp file (avoids pipe SIGPIPE with curl -F)
    local chunk_file
    chunk_file=$(mktemp)
    dd if=/dev/zero of="$chunk_file" bs=1M count=$((UPLOAD_BYTES / 1048576)) 2>/dev/null \
        || { rm -f "$chunk_file"; echo "error"; return; }

    local result speed_bps http_code
    result=$(curl -sSL -k \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "${auth_args[@]+"${auth_args[@]}"}" \
        -X PUT \
        -H "Content-Range: bytes 0-$((UPLOAD_BYTES - 1))/*" \
        -F "file=@${chunk_file}" \
        -o /dev/null \
        -w "%{speed_upload} %{http_code}" \
        "$upload_url" 2>/dev/null) || result=""
    rm -f "$chunk_file"

    # Step 3: cleanup upload session (best-effort)
    curl -sSL -k "${auth_args[@]+"${auth_args[@]}"}" -X DELETE "$upload_url" \
        -o /dev/null 2>/dev/null || true

    [[ -z "$result" ]] && { echo "error"; return; }
    read -r speed_bps http_code <<< "$result"

    if [[ "$http_code" != "200" ]]; then
        echo "http_$http_code"
        return
    fi

    local mibps
    mibps=$(awk "BEGIN { printf \"%.2f\", $speed_bps / 1048576 }")
    echo "$mibps"
}

# List all upstream-* distribution base paths from the Pulp API
list_upstream_distributions() {
    local api_url="${PULP_SERVER_URL%/}/pulp/api/v3"
    local auth_args=()
    [[ -n "${PULP_USERNAME:-}" ]] && [[ -n "${PULP_PASSWORD:-}" ]] \
        && auth_args=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")

    local rpm_dists deb_dists
    rpm_dists=$(curl -sSL -k --connect-timeout "$CONNECT_TIMEOUT" \
        "${auth_args[@]}" \
        "${api_url}/distributions/rpm/rpm/?limit=200" 2>/dev/null \
        | jq -r '.results[]? | select(.name | startswith("upstream-")) | .base_url' 2>/dev/null || true)

    deb_dists=$(curl -sSL -k --connect-timeout "$CONNECT_TIMEOUT" \
        "${auth_args[@]}" \
        "${api_url}/distributions/deb/apt/?limit=200" 2>/dev/null \
        | jq -r '.results[]? | select(.name | startswith("upstream-")) | .base_url' 2>/dev/null || true)

    printf '%s\n%s\n' "$rpm_dists" "$deb_dists" | grep -v '^$' | sort
}

# Resolve the best probe URL for a distribution — targeting a real data file
# so the speed reading reflects actual package download throughput, not just
# metadata fetch time.
#
# RPM: parse repomd.xml to find the hashed primary.xml.gz path (5–50 MB).
#      Falls back to repomd.xml if parsing fails.
# DEB: dists/<suite>/main/binary-<arch>/Packages.gz (~10–20 MB per suite).
resolve_probe_url() {
    local base_url="$1"

    if [[ "$base_url" == */upstream/ubuntu/* ]] || [[ "$base_url" == */upstream/debian/* ]]; then
        local after_distro suite arch
        after_distro=$(echo "$base_url" | sed 's|.*/upstream/[^/]*/||')
        suite=$(echo "$after_distro" | cut -d'/' -f1)
        arch=$(echo "$after_distro" | cut -d'/' -f2)
        echo "${base_url%/}/dists/${suite}/main/binary-${arch}/Packages.gz"
    else
        # Fetch repomd.xml and extract the hashed primary.xml.gz href
        local auth_args=()
        [[ -n "${PULP_USERNAME:-}" ]] && [[ -n "${PULP_PASSWORD:-}" ]] \
            && auth_args=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")

        local repomd primary_href
        repomd=$(curl -sSL -k --connect-timeout "$CONNECT_TIMEOUT" \
            "${auth_args[@]+"${auth_args[@]}"}" \
            "${base_url%/}/repodata/repomd.xml" 2>/dev/null) || true

        primary_href=$(echo "$repomd" \
            | grep -o 'href="[^"]*-primary\.xml\.gz"' \
            | head -1 \
            | sed 's/href="//;s/"//')

        if [[ -n "$primary_href" ]]; then
            echo "${base_url%/}/${primary_href}"
        else
            echo "${base_url%/}/repodata/repomd.xml"
        fi
    fi
}

# Resolve a URL pointing to an actual .rpm or .deb package for --full-package mode.
# RPM: downloads primary.xml.gz, parses the first package <location href>.
# DEB: downloads Packages.gz, parses the first Filename: entry.
# Falls back to resolve_probe_url if parsing fails.
resolve_package_url() {
    local base_url="$1"
    local auth_args=()
    [[ -n "${PULP_USERNAME:-}" ]] && [[ -n "${PULP_PASSWORD:-}" ]] \
        && auth_args=(-u "${PULP_USERNAME}:${PULP_PASSWORD}")

    if [[ "$base_url" == */upstream/ubuntu/* ]] || [[ "$base_url" == */upstream/debian/* ]]; then
        local after_distro suite arch packages_url pkg_path
        after_distro=$(echo "$base_url" | sed 's|.*/upstream/[^/]*/||')
        suite=$(echo "$after_distro" | cut -d'/' -f1)
        arch=$(echo "$after_distro" | cut -d'/' -f2)
        packages_url="${base_url%/}/dists/${suite}/main/binary-${arch}/Packages.gz"

        pkg_path=$(curl -sSL -k --connect-timeout "$CONNECT_TIMEOUT" \
            "${auth_args[@]+"${auth_args[@]}"}" \
            "$packages_url" 2>/dev/null \
            | gunzip -c 2>/dev/null \
            | grep '^Filename:' \
            | head -1 \
            | awk '{print $2}')

        if [[ -n "$pkg_path" ]]; then
            echo "${base_url%/}/${pkg_path}"
            return
        fi
    else
        # RPM: get primary.xml.gz location from repomd.xml, parse first package href
        local repomd primary_href primary_url pkg_href
        repomd=$(curl -sSL -k --connect-timeout "$CONNECT_TIMEOUT" \
            "${auth_args[@]+"${auth_args[@]}"}" \
            "${base_url%/}/repodata/repomd.xml" 2>/dev/null) || true

        primary_href=$(echo "$repomd" \
            | grep -o 'href="[^"]*-primary\.xml\.gz"' \
            | head -1 \
            | sed 's/href="//;s/"//')

        if [[ -n "$primary_href" ]]; then
            primary_url="${base_url%/}/${primary_href}"
            pkg_href=$(curl -sSL -k --connect-timeout "$CONNECT_TIMEOUT" \
                "${auth_args[@]+"${auth_args[@]}"}" \
                "$primary_url" 2>/dev/null \
                | gunzip -c 2>/dev/null \
                | grep -o '<location href="[^"]*\.rpm"' \
                | head -1 \
                | sed 's/<location href="//;s/"//')

            if [[ -n "$pkg_href" ]]; then
                echo "${base_url%/}/${pkg_href}"
                return
            fi
        fi
    fi

    # Fallback to metadata probe if package lookup fails
    resolve_probe_url "$base_url"
}

# Determine distro name from base_url for filtering
distro_from_url() {
    local url="$1"
    # Expect paths like .../upstream/<distro>/...
    echo "$url" | sed -n 's|.*/upstream/\([^/]*\)/.*|\1|p'
}

matches_distro_filter() {
    local distro="$1"
    [[ ${#FILTER_DISTROS[@]} -eq 0 ]] && return 0
    local f
    for f in "${FILTER_DISTROS[@]}"; do
        [[ "$f" == "$distro" ]] && return 0
    done
    return 1
}

# ── Output formatters ─────────────────────────────────────────────────────────

declare -a RESULT_NAMES=()
declare -a RESULT_URLS=()
declare -a RESULT_SPEEDS=()
declare -a RESULT_STATUS=()

record_result() {
    RESULT_NAMES+=("$1")
    RESULT_URLS+=("$2")
    RESULT_SPEEDS+=("$3")
    RESULT_STATUS+=("$4")
}

print_table() {
    local sep="──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    printf '%-55s  %-10s  %s\n' "Distribution" "MiB/s" "Status"
    echo "${sep:0:100}"
    local i
    for (( i=0; i<${#RESULT_NAMES[@]}; i++ )); do
        printf '%-55s  %-10s  %s\n' \
            "${RESULT_NAMES[$i]}" \
            "${RESULT_SPEEDS[$i]}" \
            "${RESULT_STATUS[$i]}"
    done
    echo "${sep:0:100}"
}

print_csv() {
    echo "name,url,mibps,status"
    local i
    for (( i=0; i<${#RESULT_NAMES[@]}; i++ )); do
        printf '"%s","%s","%s","%s"\n' \
            "${RESULT_NAMES[$i]}" \
            "${RESULT_URLS[$i]}" \
            "${RESULT_SPEEDS[$i]}" \
            "${RESULT_STATUS[$i]}"
    done
}

print_json() {
    echo "["
    local i last=$(( ${#RESULT_NAMES[@]} - 1 ))
    for (( i=0; i<${#RESULT_NAMES[@]}; i++ )); do
        local comma=","
        [[ "$i" -eq "$last" ]] && comma=""
        printf '  {"name":"%s","url":"%s","mibps":"%s","status":"%s"}%s\n' \
            "${RESULT_NAMES[$i]}" \
            "${RESULT_URLS[$i]}" \
            "${RESULT_SPEEDS[$i]}" \
            "${RESULT_STATUS[$i]}" \
            "$comma"
    done
    echo "]"
}

# ── Main ──────────────────────────────────────────────────────────────────────

parse_args "$@"

require_cmd curl
require_cmd jq
require_cmd awk

if [[ -z "$PULP_SERVER_URL" ]]; then
    echo "Error: PULP_SERVER_URL is not set. Use --server-url or export PULP_SERVER_URL." >&2
    exit 1
fi

echo "Pulp server:   $PULP_SERVER_URL"
echo "Probe mode:    $( [[ "$FULL_PACKAGE" == "true" ]] && echo "full package (.rpm/.deb)" || echo "repo metadata" )"
echo "Download size: $((PROBE_BYTES / 1048576)) MiB per distribution"
[[ "$SKIP_UPLOAD" != "true" ]] && echo "Upload size:   $((UPLOAD_BYTES / 1048576)) MiB"
[[ "$MIN_SPEED" != "0" ]] && echo "Pass threshold: ${MIN_SPEED} MiB/s"
echo "Run time:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# Enumerate upstream distributions from Pulp
echo "Fetching upstream distribution list from Pulp API ..."
DIST_URLS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && DIST_URLS+=("$line")
done < <(list_upstream_distributions)

if [[ ${#DIST_URLS[@]} -eq 0 ]]; then
    echo "No upstream-* distributions found. Run sync-upstream-repos.sh first."
    exit 0
fi

echo "Found ${#DIST_URLS[@]} distribution(s). Probing in parallel ..."
echo ""

# ── Parallel probing ──────────────────────────────────────────────────────────
# Each probe runs as a background job and writes results to a temp file.
# Format: "name|url|mibps|status"
PROBE_TMPDIR=$(mktemp -d)
trap 'rm -rf "$PROBE_TMPDIR"' EXIT

pids=()
idx=0

for base_url in "${DIST_URLS[@]}"; do
    [[ -z "$base_url" ]] && continue

    distro=$(distro_from_url "$base_url")
    matches_distro_filter "$distro" || continue

    short_name=$(echo "$base_url" | sed "s|${PULP_SERVER_URL%/}/pulp/content/||")
    result_file="$PROBE_TMPDIR/$idx.result"

    (
        if [[ "$FULL_PACKAGE" == "true" ]]; then
            probe_url=$(resolve_package_url "$base_url")
        else
            probe_url=$(resolve_probe_url "$base_url")
        fi
        speed=$(probe_speed "$probe_url")
        case "$speed" in
            [0-9]*)
                if [[ "$MIN_SPEED" != "0" ]] && awk "BEGIN { exit !($speed < $MIN_SPEED) }"; then
                    status="FAIL (${speed} MiB/s < threshold ${MIN_SPEED})"
                else
                    status="PASS"
                fi
                ;;
            http_*)  status="FAIL ($speed)" ;;
            error)   status="FAIL (connection error)" ;;
            empty)   status="WARN (empty response)" ;;
            *)       status="UNKNOWN" ;;
        esac
        printf '%s|%s|%s|%s\n' "$short_name" "$probe_url" "$speed" "$status" > "$result_file"
    ) &

    pids+=($!)
    idx=$((idx + 1))
done

# Wait for all probes to finish
echo "Waiting for ${#pids[@]} parallel probe(s) to complete ..."
for pid in "${pids[@]}"; do
    wait "$pid" || true
done

# Collect results in order
for result_file in $(ls "$PROBE_TMPDIR"/*.result 2>/dev/null | sort -V); do
    IFS='|' read -r name url speed status < "$result_file"
    record_result "$name" "$url" "$speed" "$status"
done

# Optional: compare against a direct upstream URL (sequential, single probe)
if [[ -n "$COMPARE_URL" ]]; then
    echo ""
    printf "Probing upstream comparison: %s ... " "$COMPARE_URL"
    speed=$(probe_speed "$COMPARE_URL")
    echo "${speed} MiB/s"
    record_result "(upstream direct)" "$COMPARE_URL" "$speed" "COMPARE"
fi

# ── Upload speed probe ────────────────────────────────────────────────────────
if [[ "$SKIP_UPLOAD" != "true" ]]; then
    echo ""
    printf "Probing upload speed to Pulp API (%s MiB payload) ... " "$((UPLOAD_BYTES / 1048576))"
    upload_speed=$(probe_upload_speed)
    echo "${upload_speed} MiB/s"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
pass_count=0
fail_count=0
for status in "${RESULT_STATUS[@]}"; do
    case "$status" in
        PASS)    pass_count=$((pass_count + 1)) ;;
        FAIL*)   fail_count=$((fail_count + 1)) ;;
    esac
done

echo ""
echo "── Results ──────────────────────────────────────────────────────────────────────"
case "$OUTPUT_FORMAT" in
    csv)   print_csv ;;
    json)  print_json ;;
    *)     print_table ;;
esac

echo ""
echo "Summary: ${pass_count} PASS  |  ${fail_count} FAIL  |  ${#RESULT_STATUS[@]} total"

[[ "$fail_count" -gt 0 ]] && exit 1
exit 0
