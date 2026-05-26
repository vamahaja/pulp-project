#!/bin/bash

# Set error handling
set -euo pipefail

# Pulp cluster configuration
PULP_SECRETS_YAML="./pulp-secrets.yaml"
PULP_CERT_YAML="./pulp-cert.yaml"
PULP_CLUSTER_YAML="./pulp-cluster.yaml"
PULP_OPERATOR_YAML="./pulp-operator.yaml"
PULP_INSTANCE_NAME="ceph-artifact-manager"
CERT_MANAGER_TLS_SECRET="pulp-tls-source"
PULP_ROUTE_TLS_SECRET="pulp-tls"

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
    --skip-secrets            Skip applying pulp-secrets.yaml (admin password must already exist)
    --skip-operator           Skip installing Pulp and cert-manager operators
    --help                    Show this help message and exit

Examples:
    ./deploy.sh --pulp-config ./pulp.config
    ./deploy.sh --pulp-config ./pulp.config --skip-secrets --skip-operator
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
        # shellcheck source=/dev/null
        source "$PULP_CONFIG"
    else
        echo "Error: PULP_CONFIG file $PULP_CONFIG not found!"
        exit 1
    fi
}

verify_cli() {
    echo "Checking if oc and envsubst are installed ..."
    for tool in oc envsubst; do
        if ! command -v "$tool" &> /dev/null; then
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

apply_pulp_secrets() {
    echo "Applying Pulp admin password secret from $PULP_SECRETS_YAML ..."
    envsubst < "$PULP_SECRETS_YAML" | oc apply -f -
    verify_secret_exists pulp-admin-password
}

create_route_tls_secret() {
    echo "Creating Route TLS secret '$PULP_ROUTE_TLS_SECRET' for Pulp (keys: certificate, key) ..."
    local cert_crt cert_key ca_crt
    cert_crt=$(oc get secret "$CERT_MANAGER_TLS_SECRET" \
        --namespace "$PULP_NAMESPACE" \
        -o jsonpath='{.data.tls\.crt}')
    cert_key=$(oc get secret "$CERT_MANAGER_TLS_SECRET" \
        --namespace "$PULP_NAMESPACE" \
        -o jsonpath='{.data.tls\.key}')

    if [[ -z "$cert_crt" || -z "$cert_key" ]]; then
        echo "Error: cert-manager secret '$CERT_MANAGER_TLS_SECRET' is missing tls.crt or tls.key."
        exit 1
    fi

    local oc_args=(
        --namespace="$PULP_NAMESPACE"
        --from-literal=certificate="$(echo "$cert_crt" | base64 -d)"
        --from-literal=key="$(echo "$cert_key" | base64 -d)"
    )

    ca_crt=$(oc get secret "$CERT_MANAGER_TLS_SECRET" \
        --namespace "$PULP_NAMESPACE" \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
    if [[ -n "$ca_crt" ]]; then
        oc_args+=(--from-literal=caCertificate="$(echo "$ca_crt" | base64 -d)")
    fi

    oc create secret generic "$PULP_ROUTE_TLS_SECRET" \
        "${oc_args[@]}" \
        --dry-run=client -o yaml | oc apply -f -
}

install_pulp_operator() {
    echo "Installing the Pulp and cert-manager operators ..."
    envsubst < "$PULP_OPERATOR_YAML" | oc apply -f -

    echo "Waiting for cert-manager to be installed ..."
    until oc get crd clusterissuers.cert-manager.io &>/dev/null; do sleep 5; done
    oc wait --for=condition=Available deployment/cert-manager \
        --namespace cert-manager \
        --timeout="$PULP_POD_READY_TIMEOUT"

    echo "Waiting for Pulp operator to be installed ..."
    oc wait --for=condition=ready pod \
        -l "app.kubernetes.io/name=pulp-operator" \
        --namespace "$PULP_NAMESPACE" \
        --timeout="$PULP_POD_READY_TIMEOUT"
}

verify_pulp_operator_installed() {
    echo "Verifying the Pulp operator is installed ..."
    if ! oc get csv -n "$PULP_NAMESPACE" | grep -q "pulp-operator"; then
        echo "Error: Pulp operator is not installed."
        exit 1
    fi
}

deploy_pulp_certificates() {
    echo "Applying cert-manager issuer and certificate from $PULP_CERT_YAML ..."
    envsubst < "$PULP_CERT_YAML" | oc apply -f -

    echo "Waiting for Certificate to be ready ..."
    oc wait --for=condition=Ready certificate/pulp-certificate \
        --namespace "$PULP_NAMESPACE" \
        --timeout="$PULP_POD_READY_TIMEOUT"

    create_route_tls_secret
}

deploy_pulp_instance() {
    echo "Applying Pulp CR from $PULP_CLUSTER_YAML ..."
    envsubst < "$PULP_CLUSTER_YAML" | oc apply -f -

    echo "Waiting for Pulp pods in namespace '$PULP_NAMESPACE' ..."
    oc wait --for=condition=ready pod \
        -l "app.kubernetes.io/instance=$PULP_INSTANCE_NAME" \
        --namespace "$PULP_NAMESPACE" \
        --timeout="$PULP_POD_READY_TIMEOUT"
}

deploy_pulp_cluster() {
    deploy_pulp_certificates
    deploy_pulp_instance
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

# Admin password secret (operator manages PostgreSQL and Redis credentials)
if [ "$SKIP_SECRETS" = false ]; then
    apply_pulp_secrets
else
    verify_secret_exists pulp-admin-password
fi

# Install operators
if [ "$SKIP_OPERATOR" = false ]; then
    install_pulp_operator
else
    verify_pulp_operator_installed
fi

# Issue TLS cert, build Route secret, then deploy Pulp
deploy_pulp_cluster

echo "Pulp project deployed successfully ..."

# Get the Pulp project URL
get_pulp_project_url
