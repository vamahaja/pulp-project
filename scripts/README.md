# Scripts

Helper scripts for configuring a Pulp client and managing Ceph-style repositories (RPM and Debian) on a running Pulp server.

## Prerequisites

- **Bash** – scripts require a Bash shell
- **Python 3** with **pip** – for installing the Pulp CLI and plugins
- **jq** – used by `publish-packages.sh` to parse JSON (install with `dnf install jq` or `apt install jq`)
- **Pulp server** – a Pulp instance must already be running and reachable (see the project root [README](../README.md) for deployment with Podman)

## Setup

1. **Deploy Pulp** (if not already done):

   From the project root, use the deployment script as described in the main [README](../README.md), e.g.:

   ```bash
   cd deployment && ./deploy.sh /path/to/pulp-data
   ```

2. **Make scripts executable**:

   ```bash
   chmod +x scripts/*.sh
   ```

3. **Configure the Pulp client** (required before using the other scripts):

   Set the Pulp server URL and run the client configuration script. This installs `pulp-cli` and plugins (`pulp-rpm`, `pulp-deb`, `pulp-cli-deb`) if missing, and creates the local Pulp config.

   ```bash
   export PULP_SERVER_URL="http://<host>:8080"
   ./scripts/configure-client.sh --username cephuser --password cephuser123 --overwrite
   ```

   To also grant the user the roles needed to create repositories, remotes, distributions, and publications:

   ```bash
   export PULP_ADMIN_PASSWORD=pulp123
   ./scripts/configure-client.sh --username cephuser --password cephuser123 --set-user-permissions --overwrite
   ```

## Scripts

### configure-client.sh

Sets up the Pulp CLI: installs `pulp-cli` and plugins if needed, creates client configuration for the given user, and optionally assigns Pulp roles to that user.

| Requirement | Description |
|-------------|-------------|
| **Environment** | `PULP_SERVER_URL` (required). `PULP_ADMIN_PASSWORD` (optional, default: `pulp123`) for `--set-user-permissions`. |
| **Arguments** | `--username`, `--password` (required). `--overwrite`, `--set-user-permissions` (optional). |

**Examples:**

```bash
./configure-client.sh --username cephuser --password cephuser123 --overwrite
./configure-client.sh --username cephuser --password cephuser123 --set-user-permissions --overwrite
./configure-client.sh --help
```

---

### create-ceph-repos.sh

Creates Pulp repositories for Ceph packages: one repository per combination of project, branch, distro, distro version, and architecture. Supports RPM (CentOS, Rocky) and Debian (Ubuntu) repos.

| Option | Description |
|--------|-------------|
| `--distro LIST` | Comma-separated distros (e.g. `ubuntu,centos`). Omit for all. |
| `--branches LIST` | Comma-separated Ceph branches (e.g. `reef,squid`). Omit for all. |
| `--arch LIST` | Comma-separated architectures (e.g. `x86_64,aarch64`). Omit for all. |

**Supported:** distros `ubuntu` (jammy, noble), `centos` (8, 9), `rocky` (10); architectures `noarch`, `x86_64`, `aarch64`; branches `main`, `reef`, `squid`, `tentacle`. Repo names follow: `{PROJECT}-{branch}-{distro}-{distro_version}-{arch}`. `PROJECT` defaults to `ceph` (override via environment).

**Examples:**

```bash
./create-ceph-repos.sh --help
./create-ceph-repos.sh
./create-ceph-repos.sh --distro ubuntu,centos --branches reef --arch x86_64,aarch64
```

**Prerequisite:** Run `configure-client.sh` first so `pulp` is configured and the user has permission to create repositories.

---

### publish-packages.sh

Uploads `.rpm` and/or `.deb` packages from a file or directory into the matching Pulp repository, then creates a publication and distribution for the given branch, SHA1, distro, distro version, and architecture.

| Argument / Option | Description |
|-------------------|-------------|
| `file-path` | Path to a single `.rpm`/`.deb` file or a directory containing packages (first positional argument). |
| `--branch` | Branch name (required). |
| `--sha1` | SHA1 commit hash (required). |
| `--distro` | Distribution name (required). |
| `--distro-version` | Distribution version (required). |
| `--arch` | Architecture (required). |
| `--project` | Project name (default: `ceph`). |
| `--flavor` | Flavor (default: `default`). |

Repositories must already exist (e.g. created with `create-ceph-repos.sh`). Distribution base path follows: `repos/{project}/{branch}/{sha1}/{distro}/{distro_version}/flavors/{flavor}/{arch}`.

**Examples:**

```bash
./publish-packages.sh /path/to/packages --branch main --sha1 abc123 --distro centos --distro-version 9 --arch x86_64
./publish-packages.sh ./rpms --branch reef --sha1 def456 --distro ubuntu --distro-version jammy --arch aarch64 --flavor default
./publish-packages.sh --help
```

**Prerequisites:** `jq` installed; `configure-client.sh` run; repositories created (e.g. via `create-ceph-repos.sh`).

## Typical workflow

1. Deploy Pulp and note the API URL (see main [README](../README.md)).
2. Run `configure-client.sh` with `PULP_SERVER_URL` and user credentials; use `--set-user-permissions` if the user should create repos and publish.
3. Run `create-ceph-repos.sh` (with optional `--distro`, `--branches`, `--arch`) to create the needed repositories.
4. Run `publish-packages.sh` with the package path and `--branch`, `--sha1`, `--distro`, `--distro-version`, `--arch` to upload and publish packages.

## Environment variables (summary)

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `PULP_SERVER_URL` | configure-client.sh | (required) | Pulp API base URL, e.g. `http://host:8080` |
| `PULP_ADMIN_PASSWORD` | configure-client.sh | `pulp123` | Admin password for role assignment |
| `PROJECT` | create-ceph-repos.sh, publish-packages.sh | `ceph` | Project name in repository and path names |
