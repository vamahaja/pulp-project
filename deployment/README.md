# Deployment

This directory holds deployment recipes for running Pulp in this repo. The supported path today is **Podman** with **podman-compose**.

Full instructions (prerequisites, quick start, ports, environment variables, and stack management) are in [podman/README.md](podman/README.md).

Run all deploy and `podman-compose` commands from **`deployment/podman`**, for example:

```bash
cd deployment/podman && chmod +x ./deploy.sh && ./deploy.sh /path/to/pulp-data
```

If you previously used scripts at the top level of `deployment/`, they now live under `deployment/podman/`.
