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
./deploy.sh /path/to/your/pulp_data
```

Example:

```bash
./deploy.sh /opt/pulp_data
```

The script will:

1. Create the required directories under the path you provide
2. Copy `nginx.conf` into the deployment directory
3. Generate a symmetric key for database fields under `settings/certs/`
4. Set permissions for Podman volume bind mounts
5. Start all services with `podman-compose`
6. Wait until the Pulp API is ready (checks every 20 seconds, up to ~30 minutes)

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

The script sets `PULP_API_URL` using the host’s first IP (e.g. `http://192.168.1.10:24817`) for health checks.

## Configuration

- **Database password:** Set in the script as `PULP_DB_PASSWORD` (default: `pulpdb123`). Change it in `deploy.sh` before first run if needed.
- **Base directory:** Must be passed as the first argument; there is no default path in the script (though `podman-compose.yaml` uses `./pulp_data` if `PULP_BASE_DIR` is unset when run manually).

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
