# Scripts

Helper scripts for configuring a Pulp client and managing Ceph-style repositories (RPM and Debian) on a running Pulp server.

## Prerequisites

- **Bash** – scripts require a Bash shell
- **Python 3** with **pip** – for installing the Pulp CLI and plugins
- **jq** – used by `publish-packages.sh` to parse JSON (install with `dnf install jq` or `apt install jq`)
- **Pulp server** – a Pulp instance must already be running and reachable (see the [deployment README](../deployment/README.md) for deployment with Podman)

## Setup

1. **Deploy Pulp** (if not already done):

   Use the deployment script as described in the [deployment README](../deployment/README.md), e.g.:

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
| **Environment** | `PULP_SERVER_URL` (required). For `--set-user-permissions`: `PULP_ADMIN_PASSWORD` (optional, default: `pulp123`), `PULP_ADMIN_USERNAME` (optional, default: `admin`). |
| **Arguments** | `--username`, `--password` (required). `--overwrite`, `--set-user-permissions` (optional). |

**Examples:**

```bash
./configure-client.sh --username cephuser --password cephuser123 --overwrite
./configure-client.sh --username cephuser --password cephuser123 --set-user-permissions --overwrite
./configure-client.sh --help
```

---

### create-ceph-repos.sh

Creates Pulp repositories for Ceph: (1) container image repositories with distributions, and (2) optionally package repositories (RPM/Deb) per combination of project, branch, distro, distro version, and architecture. Supports RPM (CentOS, Rocky), Debian (Ubuntu), and container image repos.

| Option | Description |
|--------|-------------|
| `--distro LIST` | Comma-separated distros (e.g. `ubuntu,centos`). Omit for all. |
| `--branches LIST` | Comma-separated Ceph branches (e.g. `reef,squid`). Omit for all. |
| `--arch LIST` | Comma-separated architectures (e.g. `x86_64,aarch64`). Omit for all. |
| `--container-repositories LIST` | Comma-separated container image repositories (e.g. `ceph,ceph-ci`). Omit for all. |

**Supported:** distros `ubuntu` (jammy, noble), `centos` (8, 9), `rocky` (10); architectures `noarch`, `x86_64`, `aarch64`; branches `main`, `reef`, `squid`, `tentacle`; container repositories `ceph`, `ceph-ci`. Package repo names follow: `{PROJECT}-{branch}-{distro}-{distro_version}-{arch}`. Container repos use the given name and a distribution with the same base path. `PROJECT` defaults to `ceph` (override via environment).

**Examples:**

```bash
./create-ceph-repos.sh --help
./create-ceph-repos.sh
./create-ceph-repos.sh --distro ubuntu,centos --branches reef --arch x86_64,aarch64
./create-ceph-repos.sh --container-repositories ceph,ceph-ci
./create-ceph-repos.sh --distro ubuntu,centos --branches reef --arch x86_64,aarch64 --container-repositories ceph,ceph-ci
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

---

### publish-image.sh

Publishes one or more local container images to a registry (e.g. a Pulp container registry) by tagging and pushing with Podman, then creates and pushes a multi-architecture manifest list for the tag. Optionally logs in first using `--username` and `--password`.

| Argument / Option | Description |
|-------------------|-------------|
| `image` or `--image LIST` | Local image name (positional) or comma-separated list of images (for multi-arch manifest). |
| `--registry` | Registry URL (required). |
| `--base-path` | Base path in the registry (required). |
| `--tag` | Tag name for the image (required). |
| `--username` | Registry username for login (optional). |
| `--password` | Registry password for login (optional). |
| `--tls-verify` | Enable TLS verification for the push (optional flag; default behavior when omitted depends on Podman). |

**Environment:** `PROJECT` (default: `ceph`).

**Examples:**

```bash
./publish-image.sh my-image --registry https://registry.example.com --base-path my-base-path --tag v1.0.0 --username user --password secret
./publish-image.sh --image img-amd64,img-arm64 --registry https://registry.example.com --base-path repos/ceph --tag reef-abc123 --tls-verify
./publish-image.sh --help
```

**Prerequisites:** Podman installed; registry must exist and be reachable. Use `--username` and `--password` for authenticated registries.

## Typical workflow

1. Deploy Pulp and note the API URL (see main [README](../README.md)).
2. Run `configure-client.sh` with `PULP_SERVER_URL` and user credentials; use `--set-user-permissions` if the user should create repos and publish.
3. Run `create-ceph-repos.sh` (with optional `--distro`, `--branches`, `--arch`, `--container-repositories`) to create the needed package and/or container image repositories.
4. Run `publish-packages.sh` with the package path and `--branch`, `--sha1`, `--distro`, `--distro-version`, `--arch` to upload and publish packages.
5. Run `publish-image.sh` with a local image (or `--image` and a comma-separated list for multi-arch), `--registry`, `--base-path`, and `--tag` to push container images and a manifest list; use `--username` and `--password` for authenticated registries.

## Environment variables (summary)

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `PULP_SERVER_URL` | configure-client.sh | (required) | Pulp API base URL, e.g. `http://host:8080` |
| `PULP_ADMIN_USERNAME` | configure-client.sh | `admin` | Admin username for role assignment |
| `PULP_ADMIN_PASSWORD` | configure-client.sh | `pulp123` | Admin password for role assignment |
| `PROJECT` | create-ceph-repos.sh, publish-packages.sh, publish-image.sh | `ceph` | Project name in repository and path names |
