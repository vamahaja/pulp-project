# Pulp Project Deployment

Deploy [Pulp](https://docs.pulpproject.org/) (content repository and distribution system) using Podman and podman-compose.

## Prerequisites

- **Podman** – container runtime
- **podman-compose** – multi-container orchestration

Install on Fedora/CentOS/Rocky:

```bash
sudo dnf install podman podman-compose
```

## Quick Start

Run the deployment script with a base directory for persistent data:

```bash
cd deployment && chmod +x ./deploy.sh
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
2. Copy `config/nginx.conf` into the deployment directory
3. Generate a symmetric key for database fields under `settings/certs/`
4. Set permissions for Podman volume bind mounts
5. Start all services with `podman-compose`
6. Wait until the Pulp API is ready (checks every 20 seconds, up to ~30 minutes)
7. Reset admin password (default: `pulp123`)
8. Create non-admin user with username and password (default: `cephuser/cephuser123`)

## What Gets Created

Under your base directory (e.g. `/opt/pulp_data`), the script creates:

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

The script sets `PULP_API_URL` using the host’s first IP for health checks.

## Configuration

Defaults are set in `deploy.sh`; override any of these via environment variables (or, for the base directory, the first script argument) before running.

| Variable | Default | Description |
|----------|---------|-------------|
| `PULP_DB_NAME` | `pulpdb` | PostgreSQL database name |
| `PULP_DB_USER` | `pulp` | PostgreSQL user |
| `PULP_DB_PASSWORD` | `pulp123` | PostgreSQL password |
| `PULP_ADMIN_PASSWORD` | `pulp123` | Pulp admin (reset after deploy) |
| `PULP_USERNAME` | `cephuser` | Pulp API user created by the script |
| `PULP_PASSWORD` | `cephuser123` | Password for `PULP_USERNAME` |
| Base directory (1st arg) | `./pulp-data` | Data directory; pass as first argument or leave unset to use default |

## Managing the Stack

From the project directory (where `podman-compose.yaml` lives):

```bash
# Use the same base directory as deploy.sh
export PULP_BASE_DIR=/path/to/your/pulp_data

# Stop services
podman-compose -f ./podman-compose.yaml down

# Start again (after initial deploy)
podman-compose -f ./podman-compose.yaml up -d

# View logs
podman-compose -f ./podman-compose.yaml logs -f
```
