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

Optional:
    --project <project>      Project name (default: ceph)
    --flavor <flavor>        Flavor (default: default)
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
    local repo_name="$PROJECT-$BRANCH-$DISTRO-$DISTRO_VERSION-$ARCH"
    local file
    local uploaded=0

    # Check if there are any packages to upload
    for file in "$FILE_PATH"/*."$ext"; do
        [ -f "$file" ] || continue
        break
    done

    # Check if there are any packages to upload
    [ -f "$file" ] || return 0

    # Check if the repository exists
    check_if_repo_exists "$repo_name" "$pkg_type"

    # Upload packages to the repository
    for file in "$FILE_PATH"/*."$ext"; do
        [ -f "$file" ] || continue

        echo "Uploading package $file to repository $repo_name"
        pulp "$pkg_type" content -t package upload --repository "$repo_name" --file "$file"
        uploaded=$((uploaded + 1))
    done
    echo "Uploaded $uploaded packages to repository $repo_name ..."

    # Create publication and distribution if any packages were uploaded
    if [ "$uploaded" -gt 0 ]; then
        echo "Creating publication and distribution for repository $repo_name ..."

        local publication_href
        publication_href=$(pulp "$pkg_type" publication create --repository "$repo_name" | jq -r '.pulp_href')
        pulp "$pkg_type" distribution create --name "$SHA1-$ARCH-$pkg_type" \
            --base-path "$BASE_PATH" --publication "$publication_href"
    fi
}

# Parse and validate
parse_arguments "$@"
validate_params

# Construct Pulp identifiers like Chacra paths
BASE_PATH="repos/${PROJECT}/${BRANCH}/${SHA1}/${DISTRO}/${DISTRO_VERSION}"
BASE_PATH="${BASE_PATH}/flavors/${FLAVOR}/${ARCH}"

# Process rpm and deb packages
process_packages "rpm"
process_packages "deb"
