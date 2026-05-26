# Pulp Project Deployment on OpenShift

Deploy [Pulp](https://docs.pulpproject.org/) on OpenShift using the [Pulp operator](https://github.com/pulp/pulp-operator) (Community Operators) and a `Pulp` custom resource. TLS for the Route is provided by [cert-manager](https://cert-manager.io/) via OLM.

## Prerequisites

- **OpenShift** cluster and **`oc`** installed; you must be logged in (`oc whoami` succeeds).
- **Permissions** to create namespaces, OLM subscriptions, and cluster-scoped resources (`ClusterIssuer`). Installing operators typically requires **cluster-admin** or equivalent.
- **`envsubst`** — substitutes variables in manifests (usually from the `gettext` package).

Install on Fedora / CentOS / Rocky:

```bash
sudo dnf install gettext
```

### Storage

`pulp-cluster.yaml` uses one `STORAGE_CLASS` for PostgreSQL, Redis, and Pulp file storage. The file-storage PVC uses **ReadWriteMany** (`file_storage_access_mode: ReadWriteMany`). Confirm your storage class supports RWX for shared artifact storage; Postgres and Redis only need RWO on most clusters.

### cert-manager

`pulp-operator.yaml` installs the **community** cert-manager operator from `community-operators`. Do **not** use this manifest if the [Red Hat cert-manager operator](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift) is already installed — only one cert-manager operator may run per cluster.

If cert-manager is already present (any supported install), use `--skip-operator` and ensure the `Certificate` / `ClusterIssuer` APIs are available before deploying.

## Directory layout

| File | Purpose |
|------|---------|
| [deploy.sh](deploy.sh) | Orchestrates install order and TLS secret mapping |
| [pulp.config.tmpl](pulp.config.tmpl) | Configuration template (copy to `pulp.config`, do not commit secrets) |
| [pulp-operator.yaml](pulp-operator.yaml) | OLM `OperatorGroup` + `Subscription` for Pulp and cert-manager |
| [pulp-secrets.yaml](pulp-secrets.yaml) | `pulp-admin-password` secret |
| [pulp-cert.yaml](pulp-cert.yaml) | `ClusterIssuer` and `Certificate` for the Route host |
| [pulp-cluster.yaml](pulp-cluster.yaml) | `Pulp` custom resource |

## Quick start

1. Copy the config template (keep secrets out of git):

   ```bash
   cd deployment/openshift && cp ./pulp.config.tmpl ./pulp.config
   ```

2. Edit `pulp.config` and set every variable (see [Configuration](#configuration)).

3. Deploy:

   ```bash
   chmod +x ./deploy.sh && ./deploy.sh --pulp-config ./pulp.config
   ```

Re-run when the admin secret and operators already exist:

```bash
./deploy.sh --pulp-config ./pulp.config --skip-secrets --skip-operator
```

## Deploy flow

`deploy.sh` applies resources in this order:

1. **Namespace** — created if missing (`PULP_NAMESPACE`).
2. **Secrets** — [pulp-secrets.yaml](pulp-secrets.yaml) → `pulp-admin-password` (skipped with `--skip-secrets`).
3. **Operators** — [pulp-operator.yaml](pulp-operator.yaml) → Pulp operator in `PULP_NAMESPACE`, cert-manager in `cert-manager` (skipped with `--skip-operator`).
4. **Certificates** — [pulp-cert.yaml](pulp-cert.yaml) → `ClusterIssuer` + `Certificate`; wait until `Certificate` is `Ready`.
5. **Route TLS secret** — `deploy.sh` reads cert-manager secret `pulp-tls-source` (`tls.crt` / `tls.key`) and creates `pulp-tls` with keys `certificate` / `key` required by the Pulp operator.
6. **Pulp instance** — [pulp-cluster.yaml](pulp-cluster.yaml) → `Pulp` CR `ceph-artifact-manager`; wait for workload pods.

PostgreSQL and Redis credentials are **not** in config; the Pulp operator creates and manages those secrets when using the internal database and cache.

## What gets created

| Resource | Name / location | Purpose |
|----------|-----------------|---------|
| Namespace | `PULP_NAMESPACE` | Pulp CR, secrets, routes, PVCs |
| Namespace | `cert-manager` | cert-manager operator (from `pulp-operator.yaml`) |
| OLM subscriptions | `pulp-operator`, `cert-manager` | Install operators from Community Operators |
| Secret | `pulp-admin-password` | Pulp admin password |
| Secret | `pulp-tls-source` | TLS material from cert-manager (`tls.crt`, `tls.key`) |
| Secret | `pulp-tls` | Route TLS for Pulp (`certificate`, `key`) |
| ClusterIssuer | `CERT_MANAGER_ISSUER_NAME` | Self-signed issuer ([pulp-cert.yaml](pulp-cert.yaml); replace for production) |
| Certificate | `pulp-certificate` | Issues cert for `PULP_ROUTE_HOST` |
| `Pulp` CR | `ceph-artifact-manager` | API, content, workers, DB, cache, storage, routes |
| Routes | `ceph-artifact-manager`, … | Operator-created routes to API/content (see below) |

PVCs and pods (PostgreSQL, Redis, Pulp components) are created by the operator from the `Pulp` spec.

## TLS and cert-manager

| Secret | Created by | Keys | Used by |
|--------|------------|------|---------|
| `pulp-tls-source` | cert-manager `Certificate` | `tls.crt`, `tls.key` | Intermediate; not referenced by Pulp |
| `pulp-tls` | `deploy.sh` after cert is Ready | `certificate`, `key` | `spec.route_tls_secret` on the `Pulp` CR |

The stock [pulp-cert.yaml](pulp-cert.yaml) defines a **self-signed** `ClusterIssuer`. Browsers and clients will not trust that CA unless you install it. For production, replace the issuer (for example ACME or your corporate CA) and keep the same `CERT_MANAGER_ISSUER_NAME` or update both the config and manifest.

## Routes and API URLs

The `Pulp` spec sets `ingress_type: route` and `route_host` from **`PULP_ROUTE_HOST`**.

- **Primary route name:** `ceph-artifact-manager`
- **Host:**

  ```bash
  oc get route ceph-artifact-manager -n "$PULP_NAMESPACE" -o jsonpath='{.spec.host}{"\n"}'
  ```

- **Status URL:** `https://<route-host>/pulp/api/v3/status/`
- **Admin auth:** password from `PULP_ADMIN_PASSWORD` in your config

The operator may create additional routes (API, content, auth) from the same `Pulp` instance.

## Configuration

Copy [pulp.config.tmpl](pulp.config.tmpl) to `pulp.config`. The deploy script **`source`**s this file; use `KEY=value` lines (no `export` required).

| Variable | Description |
|----------|-------------|
| `PULP_NAMESPACE` | Namespace for the `Pulp` CR, secrets, and routes |
| `PULP_ROUTE_HOST` | DNS name on the Route and in the TLS certificate (e.g. `pulp.apps.cluster.example.com`) |
| `STORAGE_CLASS` | Storage class for PostgreSQL, Redis, and file-storage PVCs |
| `PULP_STORAGE_SIZE` | File storage size in **Gi**, numeric only (e.g. `100`; manifest appends `Gi`) |
| `PULP_ADMIN_PASSWORD` | Pulp administrator password ([pulp-secrets.yaml](pulp-secrets.yaml)) |
| `CERT_MANAGER_ISSUER_NAME` | `ClusterIssuer` name in [pulp-cert.yaml](pulp-cert.yaml) |

Replica counts and HPA settings are fixed in [pulp-cluster.yaml](pulp-cluster.yaml); change that file or the live CR to tune scale.

## CLI options

| Option | Description |
|--------|-------------|
| `--pulp-config <file>` | **Required.** Path to the shell config file. |
| `--skip-secrets` | Do not apply [pulp-secrets.yaml](pulp-secrets.yaml); `pulp-admin-password` must already exist in `PULP_NAMESPACE`. |
| `--skip-operator` | Do not apply [pulp-operator.yaml](pulp-operator.yaml); verifies Pulp CSV exists. cert-manager must already be installed and healthy. Still runs cert issuance and deploys the `Pulp` CR. |
| `--help` | Show usage and exit. |

## Managing the deployment

Examples assume `oc` is logged in and `PULP_NAMESPACE` is set from your config:

```bash
set -a && source ./pulp.config && set +a
```

**Inspect the custom resource:**

```bash
oc get pulp ceph-artifact-manager -n "$PULP_NAMESPACE" -o yaml
```

**Check certificate status:**

```bash
oc get certificate pulp-certificate -n "$PULP_NAMESPACE"
oc get secret pulp-tls pulp-tls-source -n "$PULP_NAMESPACE"
```

**Change replicas, storage, or routes:**

Re-run `./deploy.sh`, or apply manifests with `envsubst` in the same order as [deploy.sh](deploy.sh).

**View pods:**

```bash
oc get pods -n "$PULP_NAMESPACE" -l 'app.kubernetes.io/instance=ceph-artifact-manager'
oc get pods -n "$PULP_NAMESPACE" -l 'app.kubernetes.io/name=pulp-operator'
oc get pods -n cert-manager
```

**Remove the Pulp instance** (operators and cert-manager subscription remain unless deleted separately):

```bash
oc delete pulp ceph-artifact-manager -n "$PULP_NAMESPACE"
```

Clean up secrets, certificates, PVCs, and operator subscriptions according to your retention policy. Deleting the `Pulp` CR may leave PVCs depending on operator finalizers.
