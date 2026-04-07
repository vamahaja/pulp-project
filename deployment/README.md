# Deployment

This directory holds deployment recipes for running Pulp in this repo:

- **Podman** — **podman-compose** stack on a single host.
- **OpenShift** — Pulp operator (Community Operators subscription) plus a `Pulp` custom resource rendered with `envsubst`.

## Podman

Full instructions (prerequisites, quick start, ports, environment variables, and stack management) are in [podman/README.md](podman/README.md).

Run all deploy and `podman-compose` commands from **`deployment/podman`**, for example:

```bash
cd deployment/podman && chmod +x ./deploy.sh && ./deploy.sh /path/to/pulp-data
```

## OpenShift

Full instructions (prerequisites, quick start, routes, configuration, CLI flags, and day-two operations) are in [openshift/README.md](openshift/README.md).

Run from **`deployment/openshift`**, for example:

```bash
cd deployment/openshift && chmod +x ./deploy.sh && ./deploy.sh --pulp-config ./pulp.config
```
