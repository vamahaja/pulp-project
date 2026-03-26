#!/bin/bash

# Set error handling
set -euo pipefail

# Default values
PROJECT=${PROJECT:-"ceph"}
FLAVOR=${FLAVOR:-"default"}

# Show help message
show_help() {
  cat << 'EOF'
Usage: publish-packages.sh <file-path> [OPTIONS]

    <file-path>              Path to a single .rpm/.deb file or a directory
                             containing packages

Required:
    --branch <branch>        Branch name
    --sha1 <sha1>            SHA1 commit hash
    --distro <distro>        Distribution name
    --distro-version <ver>   Distribution version
    --arch <arch>            Architecture
    --version <version>      Package version string

Optional:
    --project <project>      Project name (default: ceph)
    --flavor <flavor>        Flavor label value (default: default)
EOF
}

# Parse user arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --branch)
                BRANCH="$2"
                shift 2
                ;;
            --sha1)
                SHA1="$2"
                shift 2
                ;;
            --distro)
                DISTRO="$2"
                shift 2
                ;;
            --distro-version)
                DISTRO_VERSION="$2"
                shift 2
                ;;
            --project)
                PROJECT="$2"
                shift 2
                ;;
            --flavor)
                FLAVOR="$2"
                shift 2
                ;;
            --arch)
                ARCH="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
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
                FILE_PATH="$1"
                shift
                ;;
        esac
    done
}

# Check if the required parameters are set
validate_params() {
    if [ -z "${FILE_PATH:-}" ]; then
        echo "Error: File path is required as first argument. Use --help for usage."
        exit 1
    fi

    if [ -z "${BRANCH:-}" ]; then
        echo "Error: --branch is required. Use --help for usage."
        exit 1
    fi

    if [ -z "${SHA1:-}" ]; then
        echo "Error: --sha1 is required. Use --help for usage."
        exit 1
    fi

    if [ -z "${DISTRO:-}" ]; then
        echo "Error: --distro is required. Use --help for usage."
        exit 1
    fi

    if [ -z "${DISTRO_VERSION:-}" ]; then
        echo "Error: --distro-version is required. Use --help for usage."
        exit 1
    fi

    if [ -z "${ARCH:-}" ]; then
        echo "Error: --arch is required. Use --help for usage."
        exit 1
    fi

    if [ -z "${VERSION:-}" ]; then
        echo "Error: --version is required. Use --help for usage."
        exit 1
    fi
}

# Set pulp_labels on a deb/rpm distribution
# pulp-cli-rpm uses --distribution while pulp-cli-deb uses --name for label lookups.
set_distribution_labels() {
    local pkg_type="$1" dist_name="$2"
    local lookup_flag="--name"
    if [ "$pkg_type" = "rpm" ]; then
        lookup_flag="--distribution"
    fi

    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key ref --value "${BRANCH}"
    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key arch --value "${ARCH}"
    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key sha1 --value "${SHA1}"
    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key distro --value "${DISTRO}"
    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key flavors --value "${FLAVOR}"
    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key project --value "${PROJECT}"
    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key distro_version --value "${DISTRO_VERSION}"
    pulp "$pkg_type" distribution label set "$lookup_flag" "${dist_name}" --key version --value "${VERSION}"

    echo "Successfully applied labels on distribution ${dist_name}"
}

# Validate that a Pulp repository exists
check_if_repo_exists() {
    local repo_name="$1"
    local pkg_type="$2"

    if ! pulp "$pkg_type" repository show --name "$repo_name" &>/dev/null; then
        echo "Repository $repo_name for package type $pkg_type does not exist."
        echo "Please create it first."
        exit 1
    fi
}

# Process packages of a given type
process_packages() {
    local pkg_type="$1"
    local ext="$pkg_type"
    local repo_name
    local file
    local uploaded=0

    repo_name="$PROJECT-$BRANCH-$DISTRO-$DISTRO_VERSION-$ARCH"

    # Check if there are any packages to upload
    if ! find "$FILE_PATH" -name "*.$ext" -type f -print -quit | grep -q .; then
        return 0
    fi

    # Check if the repository exists
    check_if_repo_exists "$repo_name" "$pkg_type"

    # Upload packages to the repository (recursive find for nested layouts like pool/)
    while IFS= read -r -d '' file; do
        [ -f "$file" ] || continue
        echo "Uploading package $file to repository $repo_name"
        pulp "$pkg_type" content -t package upload --repository "$repo_name" --file "$file"
        uploaded=$((uploaded + 1))
    done < <(find "$FILE_PATH" -name "*.$ext" -type f -print0)
    echo "Uploaded $uploaded packages to repository $repo_name ..."

    # Create publication and distribution if any packages were uploaded
    if [ "$uploaded" -gt 0 ]; then
        echo "Creating publication and distribution for repository $repo_name ..."

        local dist_base_path="${BASE_PATH}/${ARCH}"
        local dist_name="$SHA1-$DISTRO-$DISTRO_VERSION-$ARCH-$pkg_type"

        local publication_href
        publication_href=$(pulp "$pkg_type" publication create --repository "$repo_name" | jq -r '.pulp_href')
        pulp "$pkg_type" distribution create --name "$dist_name" \
            --base-path "$dist_base_path" --publication "$publication_href"
        echo "Setting labels on distribution ${dist_name} ..."
        set_distribution_labels "$pkg_type" "$dist_name"
    fi
}

# Determine package type based on distro
resolve_pkg_type() {
    case "$DISTRO" in
        ubuntu)        echo "deb" ;;
        centos|rocky)  echo "rpm" ;;
        *)
            echo "Error: unsupported distro '$DISTRO'" >&2
            exit 1
            ;;
    esac
}

# Parse and validate
parse_arguments "$@"
validate_params

# Construct Pulp identifiers like Chacra paths
PKG_TYPE=$(resolve_pkg_type)
BASE_PATH="repos/${PROJECT}/${BRANCH}/${SHA1}/${DISTRO}/${DISTRO_VERSION}"
BASE_PATH="${BASE_PATH}/flavors/${FLAVOR}"

# Process packages
process_packages "$PKG_TYPE"
