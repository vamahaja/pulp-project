# Pulp Project

Deploy and manage [Pulp](https://docs.pulpproject.org/) (content repository and distribution system) with Podman, and use helper scripts to configure clients and manage Ceph repositories (RPM and Debian) on a running Pulp server.

## Overview

| Directory     | Description |
|---------------|--------------|
| **[deployment/](deployment/)** | Deploy Pulp with Podman and podman-compose: persistent data dirs, Nginx, PostgreSQL, Redis, Pulp API/content/worker. See [deployment/README.md](deployment/README.md) for an overview; full steps in [deployment/podman/README.md](deployment/podman/README.md). |
| **[scripts/](scripts/)** | Configure the Pulp CLI, create Ceph repos, and publish packages. See [scripts/README.md](scripts/README.md) for setup and usage. |

## Quick start

1. **Deploy Pulp** (from the repo root):

   ```bash
   cd deployment/podman && chmod +x ./deploy.sh && ./deploy.sh /opt/pulp-data
   ```

2. **Configure the client and create repos** (see [scripts/README.md](scripts/README.md)):

   ```bash
   export PULP_SERVER_URL="http://<host>:8080"
   chmod +x scripts/*.sh
   ./scripts/configure-client.sh --username cephuser --password cephuser123 --set-user-permissions --overwrite
   ./scripts/create-ceph-repos.sh   # optional: --distro, --branches, --arch, --container-repositories
   ```

3. **Publish packages or container images** when needed:

   ```bash
   ./scripts/publish-packages.sh /path/to/packages --branch main --sha1 <sha1> --distro centos --distro-version 9 --arch x86_64
   ./scripts/publish-image.sh <image> --registry http://<host>:8080 --base-path ceph --tag main-abc123 --username cephuser --password cephuser123
   ```

Default credentials after deploy: admin `pulp123`, user `cephuser` / `cephuser123`. API and docs: `http://<host>:8080/pulp/api/` and `http://<host>:8080/pulp/api/v3/docs/`.
