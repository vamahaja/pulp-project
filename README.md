# Pulp Project

Deploy and manage [Pulp](https://docs.pulpproject.org/) (content repository and distribution system) using podman-compose (Podman) or OpenShift, and use helper scripts to configure clients and manage Ceph repositories (RPM and Debian) on a running Pulp server.

## Overview

Deployment targets (Podman, OpenShift) and automation surfaces (CLI; REST API TODO). Follow the links for steps and prerequisites.

| Approach | Description |
|----------|-------------|
| Podman | `podman-compose` stack (`Nginx`, `PostgreSQL`, `Redis`, `Pulp`). See [deployment](deployment/README.md) and [podman](deployment/podman/README.md). |
| OpenShift | Pulp operator plus `Pulp` CR via [OpenShift](deployment/openshift/deploy.sh). See [deployment](deployment/README.md) and [OpenShift](deployment/openshift/README.md). |
| CLI | Configure the Pulp CLI, create Ceph repos, and publish packages. See [scripts](scripts/README.md) for setup and usage. |
| REST API | TODO |
