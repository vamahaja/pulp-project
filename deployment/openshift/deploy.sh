#!/bin/bash

# Set error handling
set -euo pipefail

# Pulp cluster configuration
PULP_CLUSTER_YAML="./pulp-cluster.yaml"
PULP_OPERATOR_YAML="./pulp-operator.yaml"
PULP_INSTANCE_NAME="ceph-artifact-manager"

# Pulp pod ready timeout
PULP_POD_READY_TIMEOUT=300s

# Set default parameters
SKIP_SECRETS=false
SKIP_OPERATOR=false

show_help() {
    cat << 'EOF'
Deploy a Pulp project cluster on OpenShift.

Usage: ./deploy.sh [OPTIONS]

Required:
    --pulp-config <file>      Path to the Pulp configuration file

Optional:
    --skip-secrets            Skip creating Pulp project secrets
    --skip-operator           Skip installing Pulp operator
    --help                    Show this help message and exit

Examples:
    ./deploy.sh --pulp-config ./pulp.config.tmpl
    ./deploy.sh --pulp-config ./pulp.config.tmpl --skip-secrets --skip-operator
    ./deploy.sh --help
EOF
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --pulp-config)
                PULP_CONFIG="$2"
                shift 2
                ;;
            --skip-secrets)
                SKIP_SECRETS=true
                shift
                ;;
            --skip-operator)
                SKIP_OPERATOR=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown parameter passed: $1"
                exit 1
                ;;
        esac
    done
}

load_config() {
    echo "Loading configuration from $PULP_CONFIG ..."
    if [ -f "$PULP_CONFIG" ]; then
        source "$PULP_CONFIG"
    else
        echo "Error: PULP_CONFIG file $PULP_CONFIG not found!"
        exit 1
    fi
}

verify_cli() {
    echo "Checking if oc and envsubst are installed ..."
    for tool in oc envsubst; do
        if ! command -v $tool &> /dev/null; then
            echo "Error: $tool is not installed."
            exit 1
        fi
    done

    echo "Checking if oc is logged in ..."
    if ! oc whoami &> /dev/null; then
        echo "Error: oc is not logged in."
        exit 1
    fi

    echo "Checking if namespace $PULP_NAMESPACE exists ..."
    if ! oc get namespace "$PULP_NAMESPACE" &> /dev/null; then
        echo "Namespace $PULP_NAMESPACE does not exist, creating it ..."
        oc create namespace "$PULP_NAMESPACE"
    else
        echo "Namespace $PULP_NAMESPACE exists, using it ..."
        oc project "$PULP_NAMESPACE"
    fi
}

verify_secret_exists() {
    local secret_name=$1
    if ! oc get secret "$secret_name" --namespace "$PULP_NAMESPACE" &> /dev/null; then
        echo "Error: secret '$secret_name' not found in namespace '$PULP_NAMESPACE'."
        exit 1
    fi
    echo "Verified secret '$secret_name' exists in namespace '$PULP_NAMESPACE'."
}

create_pulp_secrets() {
    echo "Creating the global Admin password secret ..."
    oc create secret generic pulp-admin-password \
        --namespace "$PULP_NAMESPACE" \
        --from-literal=password="$PULP_ADMIN_PASSWORD"
    verify_secret_exists pulp-admin-password

    echo "Creating the PostgreSQL credentials secret for the internal database ..."
    oc create secret generic pulp-postgres-credentials \
        --namespace "$PULP_NAMESPACE" \
        --from-literal=username="pulp_user" \
        --from-literal=password="$POSTGRES_PASSWORD" \
        --from-literal=database="pulp_db"
    verify_secret_exists pulp-postgres-credentials

    echo "Creating the Redis credentials secret for the internal cache ..."
    oc create secret generic pulp-redis-credentials \
        --namespace "$PULP_NAMESPACE" \
        --from-literal=password="$REDIS_PASSWORD"
    verify_secret_exists pulp-redis-credentials
}

install_pulp_operator() {
    echo "Installing the Pulp operator ..."
    oc apply -f "$PULP_OPERATOR_YAML"

    echo "Waiting for Pulp operator to be installed ..."
    oc wait --for=condition=ready pod \
        -l "app.kubernetes.io/name=pulp-operator" \
        --namespace "$PULP_NAMESPACE" \
        --timeout="$PULP_POD_READY_TIMEOUT"
}

verify_pulp_operator_installed() {
    echo "Verifying the Pulp operator is installed ..."
    if ! oc get csv -n "$PULP_NAMESPACE" | grep "pulp-operator"; then
        echo "Error: Pulp operator is not installed."
        exit 1
    fi
}

deploy_pulp_cluster() {
    echo "Processing $PULP_CLUSTER_YAML and deploying to OpenShift ..."
    envsubst < "$PULP_CLUSTER_YAML" | oc apply -f -

    echo "Waiting for Pulp pods in namespace '$PULP_NAMESPACE' ..."
    oc wait --for=condition=ready pod \
        -l "app.kubernetes.io/instance=$PULP_INSTANCE_NAME" \
        --namespace "$PULP_NAMESPACE" \
        --timeout="$PULP_POD_READY_TIMEOUT"
}

get_pulp_project_url() {
    echo "Getting the Pulp project URL ..."
    local host
    host=$(oc get route "$PULP_INSTANCE_NAME" \
        --namespace "$PULP_NAMESPACE" \
        --template='{{.spec.host}}')
    echo "Pulp project URL: https://${host}/pulp/api/v3/status/"
}

echo "Starting Pulp Project deployment preparation ..."

# Parse user arguments
parse_arguments "$@"

# Load user configuration
load_config

# Verify OpenShift CLI
verify_cli

# Create Pulp project secrets
if [ "$SKIP_SECRETS" = false ]; then
    create_pulp_secrets
fi

# Install Pulp operator
if [ "$SKIP_OPERATOR" = false ]; then
    install_pulp_operator
else
    verify_pulp_operator_installed
fi

# Deploy Pulp project
deploy_pulp_cluster

echo "Pulp project deployed successfully ..."

# Get the Pulp project URL
get_pulp_project_url
