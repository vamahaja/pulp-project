# Pulp Project Deployment

Parent overview: [../README.md](../README.md).

Deploy [Pulp](https://docs.pulpproject.org/) (content repository and distribution system) using Podman and podman-compose.

## Prerequisites

- **Podman** – container runtime
- **podman-compose** – multi-container orchestration

Install on Fedora/CentOS/Rocky:

```bash
sudo dnf install podman podman-compose
```

Run `deploy.sh` as the **same (rootless) user** that will own the containers; that user must be able to run `podman` and `loginctl enable-linger` (typically from a logged-in session).

**Directory layout:** `deployment/podman` contains `deploy.sh`, `podman-compose.yaml`, `config/nginx.conf`. All deployment and management commands below are run from the **`deployment/podman`** directory.

## Quick Start

From the **`deployment/podman`** directory, run the deployment script with a base directory for persistent data:

```bash
cd deployment/podman && chmod +x ./deploy.sh
```

```bash
./deploy.sh /path/to/your/pulp-data
```

Example:

```bash
./deploy.sh /opt/pulp-data
```

The script will:

1. Create the required directories under the path you provide
2. Copy `config/nginx.conf` into the base data directory at `nginx_conf/nginx.conf`
3. Generate under `settings/certs/`: a symmetric key for database fields, and a key pair for container token auth
4. Set permissions for Podman volume bind mounts
5. Enable linger for the current user (so rootless containers keep running after logout)
6. Start all services with `podman-compose`
7. Wait until the Pulp API is ready (checks every 20 seconds, up to about 30 minutes)
8. Reset the admin password (default: `pulp123`)
9. Create a non-admin user (default: `cephuser` / `cephuser123`)

## What Gets Created

Under your base directory (e.g. `/opt/pulp-data`), the script creates:

| Directory     | Purpose                          |
|---------------|----------------------------------|
| `pgsql`       | PostgreSQL data                  |
| `pulp_storage`| Pulp file storage                |
| `settings`    | Pulp config and `certs/`         |
| `redis_data`  | Redis persistence                |
| `nginx_conf`  | Nginx config (copy of `nginx.conf`) |

## Ports

| Service       | Port  | Description                    |
|---------------|-------|--------------------------------|
| Pulp API      | 24817 | Direct API access              |
| Pulp Content  | 24816 | Content service                |
| Web (Nginx)   | 8080  | Reverse proxy (API + content)   |

- **API (direct):** `http://<host>:24817/pulp/api/v3/`
- **API (via Nginx):** `http://<host>:8080/pulp/api/`
- **Content (via Nginx):** `http://<host>:8080/pulp/content/`
- **Documentation (via Nginx):** `http://<host>:8080/pulp/api/v3/docs/`

The script sets `PULP_API_URL` and `PULP_SERVER_URL` from the host’s first IP for health checks and user creation.

## Configuration

Defaults are set in `deploy.sh`; override any of these via environment variables (or, for the base directory, the first script argument) before running.

| Variable | Default | Description |
|----------|---------|-------------|
| `PULP_BASE_DIR` | Set from 1st arg or `./pulp-data` | Base data path; set by the script. **Must be exported** when running `podman-compose` (down/up/logs) and must match the path used with `deploy.sh`. |
| `PULP_DB_NAME` | `pulpdb` | PostgreSQL database name |
| `PULP_DB_USER` | `pulp` | PostgreSQL user |
| `PULP_DB_PASSWORD` | `pulp123` | PostgreSQL password |
| `PULP_ADMIN_PASSWORD` | `pulp123` | Pulp admin (reset after deploy) |
| `PULP_USERNAME` | `cephuser` | Pulp API user created by the script |
| `PULP_PASSWORD` | `cephuser123` | Password for `PULP_USERNAME` |
| Base directory (1st arg) | `./pulp-data` | Data directory; pass as first argument or leave unset to use default |

The script also sets `PULP_API_URL` and `PULP_SERVER_URL` from the host’s first IP (used for health checks and creating the API user).

## Managing the Stack

From the **`deployment/podman`** directory, run `podman-compose` with **`PULP_BASE_DIR` set to the same path you passed to `deploy.sh`** (e.g. `/opt/pulp-data`). If it is unset or different, the compose stack may use or create a different data path and not match your existing deployment.

```bash
# Must match the path you used with deploy.sh
export PULP_BASE_DIR=/path/to/your/pulp-data

# Stop services
podman-compose -f ./podman-compose.yaml down

# Start again (after initial deploy)
podman-compose -f ./podman-compose.yaml up -d

# View logs
podman-compose -f ./podman-compose.yaml logs -f
```
