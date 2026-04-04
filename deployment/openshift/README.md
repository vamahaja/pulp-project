# Pulp Project Deployment on OpenShift

Deploy [Pulp](https://docs.pulpproject.org/) on OpenShift using the [Pulp operator](https://github.com/pulp/pulp-operator) (Community Operators subscription) and a `Pulp` custom resource.

## Prerequisites

- **OpenShift** cluster and **`oc`** installed; you must be logged in (`oc whoami` succeeds).
- **`envsubst`** — substitute environment variables in manifests (usually from the `gettext` package).

Install on `Fedora`/`CentOs`/`Rocky`:

```bash
sudo dnf install gettext
```

**Directory layout:** `deployment/openshift` contains `deploy.sh`, `pulp-operator.yaml`, `pulp-cluster.yaml`, and `pulp.config.tmpl`.

## Quick start

1. Copy the config template to a local file (keep secrets out of git):

   ```bash
   cd deployment/openshift && cp ./pulp.config.tmpl ./pulp.config
   ```

2. Edit `pulp.config`: set every variable (see [Configuration](#configuration)).

3. Deploy:

   ```bash
   chmod +x ./deploy.sh && ./deploy.sh --pulp-config ./pulp.config
   ```

Example with skips for a re-run when secrets and the operator already exist:

```bash
./deploy.sh --pulp-config ./pulp.config --skip-secrets --skip-operator
```

## What gets created

| Resource | Name / note | Purpose |
|----------|-------------|---------|
| Namespace | `PULP_NAMESPACE` (from config) | Workload and secrets for this deploy |
| Secrets | `pulp-admin-password`, `pulp-postgres-credentials`, `pulp-redis-credentials` | Credentials referenced by the `Pulp` CR |
| Custom Resource `Pulp` | `ceph-artifact-manager` | Pulp API, content, workers, DB, cache, storage, Route |
| Route | `ceph-artifact-manager` | Ingress to Pulp (see [Routes and API URLs](#routes-and-api-urls)) |

PVCs and pods are created by the operator from the `Pulp` spec (PostgreSQL, Redis, file storage, Pulp components).

## Routes and API URLs

The `Pulp` spec sets `ingress_type: route` and `route_host` from **`ROUTE_HOST`** in your config.

- **Route name:** `ceph-artifact-manager`
- **Host:** `oc get route ceph-artifact-manager -n "$PULP_NAMESPACE" -o jsonpath='{.spec.host}{"\n"}'`

Typical client base URL (TLS depends on your Route):

- **`PULP_SERVER_URL`:** Use `https://<route-host>` for package operations.
- **Status:** `https://<route-host>/pulp/api/v3/status/`.
- **`PULP_ADMIN_PASSWORD`:** Use for administrator operations.

## Configuration

Copy [pulp.config.tmpl](pulp.config.tmpl) to a file such as `pulp.config` and replace placeholders. The deploy script **`source`** this file; use `KEY=value` lines.

| Variable | Description |
|----------|-------------|
| `PULP_NAMESPACE` | Namespace for the `Pulp` CR, secrets, and Route. Use `pulp-infra` with the stock operator YAML. |
| `API_REPLICAS` | Pulp API replica count |
| `CONTENT_REPLICAS` | Pulp content replica count |
| `WORKER_REPLICAS` | Pulp worker replica count |
| `ROUTE_HOST` | Hostname for the OpenShift Route (e.g. `pulp.apps.example.com`) |
| `POSTGRES_STORAGE_CLASS` | Storage class for PostgreSQL PVC |
| `FILE_STORAGE_STORAGE_CLASS` | Storage class for Pulp file storage (`ReadWriteMany` in [pulp-cluster.yaml](pulp-cluster.yaml)) |
| `REDIS_STORAGE_CLASS` | Storage class for Redis |
| `DB_STORAGE` | PostgreSQL volume size (e.g. `50Gi`) |
| `FILE_STORAGE` | File storage size (e.g. `100Gi`) |
| `REDIS_PASSWORD` | Redis password (secret `pulp-redis-credentials`) |
| `PULP_ADMIN_PASSWORD` | Pulp admin password (secret `pulp-admin-password`) |
| `POSTGRES_PASSWORD` | PostgreSQL password (secret `pulp-postgres-credentials`; DB user is fixed as `pulp_user`, database `pulp_db` in `deploy.sh`) |

## CLI options

| Option | Description |
|--------|-------------|
| `--pulp-config <file>` | **Required.** Path to the shell config file. |
| `--skip-secrets` | Do not create Pulp secrets (must be already exist in `PULP_NAMESPACE`). |
| `--skip-operator` | Do not apply `pulp-operator.yaml`; only check CSV, then apply the `Pulp` CR. |

## Managing the deployment

All examples assume `oc` is logged in and `PULP_NAMESPACE` matches your config.

**Inspect the custom resource:**

```bash
oc get pulp ceph-artifact-manager -n "$PULP_NAMESPACE" -o yaml
```

**Change replicas or storage (after editing `pulp.config` values):**

Re-run `envsubst` and apply, or edit the live CR. Example re-apply from this directory:

```bash
set -a && source ./pulp.config && set +a
envsubst < ./pulp-cluster.yaml | oc apply -f -
```

**View operator and workload pods:**

```bash
oc get pods -n "$PULP_NAMESPACE" -l 'app.kubernetes.io/instance=ceph-artifact-manager'
oc get pods -n pulp-infra -l 'app.kubernetes.io/name=pulp-operator'
```

**Remove the Pulp instance** (does not remove the operator subscription unless you delete those objects separately):

```bash
oc delete pulp ceph-artifact-manager -n "$PULP_NAMESPACE"
```

Clean up secrets and PVCs according to your retention policy; removing the `Pulp` CR may leave PVCs depending on operator behavior and finalizers.
