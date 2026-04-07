# Pulp Project

Deploy and manage [Pulp](https://docs.pulpproject.org/) (content repository and distribution system) using **Podman** (`podman-compose`) or **OpenShift** (Pulp operator). Use the shell helpers under `scripts/` to configure the Pulp CLI, create Ceph-style RPM/Debian and container repositories, **upload packages from disk** or **sync from a Chacra-style upstream**, and **publish container images** with Podman.

## Overview

Deployment targets and automation surfaces (CLI; REST API TODO). Follow the links for prerequisites and step-by-step usage.

| Approach | Description |
|----------|-------------|
| Podman | `podman-compose` stack (`Nginx`, `PostgreSQL`, `Redis`, `Pulp`). See [deployment](deployment/README.md) and [podman](deployment/podman/README.md). |
| OpenShift | Pulp operator plus `Pulp` CR via `deployment/openshift/deploy.sh`. See [deployment](deployment/README.md) and [OpenShift](deployment/openshift/README.md). |
| CLI | `configure-client.sh`, `create-ceph-repos.sh`, `publish-packages.sh` (local artifacts), `sync-packages.sh` (mirror from Chacra or compatible URL), `publish-image.sh`. Details in [scripts](scripts/README.md). |
| REST API | TODO |

## Quick path

1. Deploy Pulp from [deployment/podman](deployment/podman/README.md) or [deployment/openshift](deployment/openshift/README.md).
2. Run [scripts](scripts/README.md): configure the client, create repos, then either publish local packages or sync from upstream, and push images as needed.
