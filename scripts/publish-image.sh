#!/bin/bash

# Set error handling
set -euo pipefail

# Default values
PROJECT=${PROJECT:-"ceph"}

# Show help message
show_help() {
  cat << 'EOF'
Usage: publish-image.sh [OPTIONS...]

Required:
    --image LIST                Comma-separated local image names
    --registry REGISTRY         Registry URL
    --base-path BASE_PATH       Base path in the registry
    --tag TAG                   Tag name for the image
    --username USERNAME         Username for authentication
    --password PASSWORD         Password for authentication
    --tls-verify                Enable TLS verification for the push
                                (optional flag, default: true)

Environment:
    PROJECT             Project name for image names (default: ceph)

Examples:
    publish-image.sh --image my-image --registry https://registry.example.com --base-path my-base-path --tag v1.0.0 --tls-verify
    publish-image.sh --image img-amd64,img-arm64 --registry https://registry.example.com --base-path repos/ceph --tag reef-abc123 --tls-verify
    publish-image.sh --help
EOF
}

# Parse user arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --image)
                [[ $# -lt 2 ]] && { echo "Error: --image requires a value" >&2; exit 1; }
                IFS=',' read -ra IMAGES <<< "$2"
                shift 2
                ;;
            --registry)
                [[ $# -lt 2 ]] && { echo "Error: --registry requires a value" >&2; exit 1; }
                REGISTRY="$2"
                shift 2
                ;;
            --base-path)
                [[ $# -lt 2 ]] && { echo "Error: --base-path requires a value" >&2; exit 1; }
                BASE_PATH="$2"
                shift 2
                ;;
            --tag)
                [[ $# -lt 2 ]] && { echo "Error: --tag requires a value" >&2; exit 1; }
                TAG="$2"
                shift 2
                ;;
            --username)
                [[ $# -lt 2 ]] && { echo "Error: --username requires a value" >&2; exit 1; }
                USERNAME="$2"
                shift 2
                ;;
            --password)
                [[ $# -lt 2 ]] && { echo "Error: --password requires a value" >&2; exit 1; }
                PASSWORD="$2"
                shift 2
                ;;
            --tls-verify)
                TLS_VERIFY=true
                shift 1
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

# Get image architecture
get_image_architecture() {
    local image="$1"
    podman inspect --format '{{.Architecture}}' "$image"
}

# Login to registry
login_to_registry() {
    if [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ]; then
        echo "Logging in to registry $REGISTRY with username $USERNAME"
        if ! podman login $REGISTRY -u $USERNAME -p $PASSWORD; then
            echo "Error: failed to login to registry $REGISTRY with username $USERNAME" >&2
            exit 1
        fi
    else
        echo "No credentials provided, skipping login to registry $REGISTRY"
    fi
}

# Tag and push image
publish_image() {
    local image arch
    for image in "${IMAGES[@]}"; do
        arch=$(get_image_architecture "$image")
        echo "Publishing image $image (architecture: $arch) to registry $REGISTRY"

        podman tag "$image" "$REGISTRY/$BASE_PATH/$PROJECT:$TAG-$arch"
        podman push --tls-verify=${TLS_VERIFY:-false} "$REGISTRY/$BASE_PATH/$PROJECT:$TAG-$arch"
    done
}

# Update manifest list
update_manifest_list() {
    local image arch manifest_list

    # Create manifest list
    manifest_list="$BASE_PATH-$PROJECT:$TAG"
    podman manifest create "$manifest_list"

    # Add images to manifest list
    for image in "${IMAGES[@]}"; do
        arch=$(get_image_architecture "$image")
        echo "Updating manifest list for image $image (architecture: $arch)"

        podman manifest add "$manifest_list" "docker://$REGISTRY/$BASE_PATH/$PROJECT:$TAG-$arch"
    done

    # Push manifest list
    podman manifest push --tls-verify=$TLS_VERIFY "$manifest_list" "$REGISTRY/$BASE_PATH/$PROJECT:$TAG"
}

# Parse user arguments
parse_arguments "$@"

# Login to registry
login_to_registry

# Publish image
publish_image

# Update manifest list
update_manifest_list
