# Cluster API Provider Meta (CAPM)

## What is Cluster API Provider Meta

Cluster API Provider Meta (CAPM) is a **Cluster API infrastructure provider** that can be used to create a cluster where different infrastructure providers are used.

> NOTE: this provider is currently a proof-of-concept and is not suitable for usage.

## Getting started

These are the recommended steps for engineers to get started when working on the project:

1. Ensure **Tilt** and **kind** are installed
2. Clone the [Cluster API Repo](https://github.com/kubernetes-sigs/cluster-api). Make sure you use the **main** branch.
3. Clone this repo
4. Create a `tilt-settings.yaml` file in the cloned **cluster-api** repo
5. Add the following contents (see [here](https://cluster-api.sigs.k8s.io/developer/tilt) for additional settings):
```yaml
default_registry: gcr.io/yourname
provider_repos:
- ../cluster-api-provider-meta
enable_providers:
- meta
- kubeadm-bootstrap
- kubeadm-control-plane
kustomize_substitutions:
  EXP_CLUSTER_RESOURCE_SET: "true"
  EXP_MACHINE_POOL: "true"
debug:
  meta:
    continue: true
    port: 30000
    profiler_port: 40000
    metrics_port: 40001
```

6. Open a terminal in this repo and run:

```bash
make kind-cluster
```
7. Wait for the command to complete
8. Open a second terminal in the **cluster-api** repo and run:

```bash
tilt up
```

9. Press the **Space** key and use the Tilt web ui to watch everything start. Everything should turn green.
