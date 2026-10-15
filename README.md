# K3s DDS (Data Distribution Service) Deployment

A comprehensive Kubernetes (K3s) deployment framework for running RTI DDS applications, including Shapes publisher/subscriber examples, Cloud Discovery Service, and Routing Service components. This repository uses Antrea as the default cluster CNI, but also supports Flannel as an alternative for K3s networking. Multiple deployment modes are provided for local, multi-node, and cloud-based WAN scenarios.

## Customer Documentation Export

This repository includes the deployment configuration, scripts, source, guides, and diagrams, but excludes the RTI Connext runtime executables and shared libraries. Building or running the demo requires the corresponding files from a properly licensed RTI Connext installation. The container builds in this repository will not work until those runtime files are supplied.

## Overview

This project facilitates the deployment and management of DDS-based applications on K3s clusters. It includes:

- **Shapes Publisher/Subscriber Applications**: RTI DDS example applications demonstrating publish-subscribe patterns
- **Cloud Discovery Service (CDS)**: Enables discovery across the cluster when multicast is not available
- **Routing Service**: Bridges DDS traffic between different network interfaces and domains
- **CNI Networking**: Antrea is the default cluster CNI; node deployment also supports Flannel for K3s networking scenarios.
- **Network Topologies**: Support for local deployments, multi-node setups, cloud integration, and WAN scenarios

## Directory Structure

| Directory | Description |
|-----------|-------------|
| `_scripts/` | Contains utility scripts for cluster setup, deployment, cleanup, and diagnostics. |
| `_antrea/` | Contains Antrea CNI configuration. |
| `_common/` | Contains shared workload manifests. |
| `_example/` | Contains example configuration files. |
| `_helper_yaml/` | Contains helper YAML installers and utilities for CNI-related setup. |
| `_network_attachments/` | Contains Kubernetes network attachment definitions for Multus/MACVLAN. |
| `_offline_assets/` | Contains local fallback manifests and supporting assets for offline deployments. |
| `containers/` | Contains Dockerfiles and runtime assets for CDS, Routing Service, and Shapes applications. |
| `docs/` | Contains deployment guides and slide assets. |
| `shapes_src/` | Contains RTI DDS Shapes source code and build artifacts. |

## Deployment Modes

The deployment system supports 7 different modes, each tailored for specific use cases:

| Mode | Description | Use Cases | Command |
|------|-------------|-----------|---------|
| 1 | CNI with No Multicast | Works with both Antrea (multicast disabled) and Flannel | <nobr><code>./_scripts/deploy_pods.sh -m 1</code></nobr> |
| 2 | Antrea CNI with Multicast Enabled | Multicast-enabled deployment | <nobr><code>./_scripts/deploy_pods.sh -m 2</code></nobr> |
| 3 | MACVLAN on All Pods | Enables multicast by leveraging MACVLAN interface and exposes all pods to the external network | <nobr><code>./_scripts/deploy_pods.sh -m 3</code></nobr> |
| 4 | MACVLAN on Routing Service Only | Enables multicast by leveraging the MACVLAN interface only for Routing Service. Routing Service acts as bridge between Nodes within the cluster. | <nobr><code>./_scripts/deploy_pods.sh -m 4</code></nobr> |
| 5 | Cloud Discovery Service (CDS) | Enables DDS communication when multicast is not supported | <nobr><code>./_scripts/deploy_pods.sh -m 5</code></nobr> |
| 6 | Routing Service to Cloud | Uses Routing Service to communicate from the cluster to DDS applications in the cloud; | <nobr><code>./_scripts/deploy_pods.sh -m 6</code></nobr> |
| 7 | NodePort External Access | Allows DDS applications external to the cluster to communicate with DDS applications inside the cluster | <nobr><code>./_scripts/deploy_pods.sh -m 7</code></nobr> |

## Scenario Guides

The deployment guides listed below include runbooks with the matching deployment slide and step-by-step setup instructions:

- Mode 1 (Antrea, Multicast Disabled): [`docs/deployment-guides/mode-1-antrea-multicast-disabled.md`](docs/deployment-guides/mode-1-antrea-multicast-disabled.md)
- Mode 1 (Flannel): [`docs/deployment-guides/mode-1-flannel-multicast-disabled.md`](docs/deployment-guides/mode-1-flannel-multicast-disabled.md)
- Mode 2 (Antrea CNI with Multicast): [`docs/deployment-guides/mode-2-antrea-multicast.md`](docs/deployment-guides/mode-2-antrea-multicast.md)
- Mode 3 (MACVLAN on All Pods): [`docs/deployment-guides/mode-3-macvlan-all-pods.md`](docs/deployment-guides/mode-3-macvlan-all-pods.md)
- Mode 4 (MACVLAN on Routing Service Only): [`docs/deployment-guides/mode-4-macvlan-routing-service-only.md`](docs/deployment-guides/mode-4-macvlan-routing-service-only.md)
- Mode 5 (Cloud Discovery Service): [`docs/deployment-guides/mode-5-cloud-discovery-service.md`](docs/deployment-guides/mode-5-cloud-discovery-service.md)
- Mode 6 (Routing Service to Cloud): [`docs/deployment-guides/mode-6-routing-service-to-cloud.md`](docs/deployment-guides/mode-6-routing-service-to-cloud.md)
- Mode 7 (NodePort External Access): [`docs/deployment-guides/mode-7-nodeport-external-access.md`](docs/deployment-guides/mode-7-nodeport-external-access.md)

## Scripts in `_scripts/`

All scripts use `kubectl` for cluster operations and accept pod selections interactively via numbered menus.

### Cluster Setup

| Script | Purpose | Options |
|--------|---------|----------|
| `deploy_node.sh` | Initializes K3s nodes (control-plane/worker), renders and installs registry configuration from the shared template, labels nodes for publisher color assignment, and runs CNI cleanup when switching CNIs. | `-c IP` (control_plane_ip), `-r HOST` (remote), `-u USER` (username), `-p PASSWORD` (optional, uses SSH keys if omitted), `-n CNI` (`antrea` or `flannel`, default: `antrea`) |
| `deploy_pods.sh` | Deploys mode-specific workloads from shared `_common` and automatically cleans existing Shapes workloads/services before redeploying. | `-m MODE` (1-7, required) |

### Cluster Management

| Script | Purpose | Options |
|--------|----------|---------|
| `clean.sh` | Cleans old deployments or performs Shapes-only cleanup. | `--shapes-only` (remove Shapes workloads and user services only) |
| `build_cni_plugins_assets_image.sh` | Builds and pushes the offline CNI plugins assets image used by `cni-plugins-installer`. | `-m MIRROR` (required) |
| `delete_resources.sh` | Interactively selects and deletes specific resources. | (none) |
| `mirror_offline_images.sh` | Pulls, retags, and pushes all images required for offline deployment to a local mirror registry. | `-m MIRROR` (required), `-k` (keep local tags) |
| `refresh_offline_assets.sh` | Refreshes local Multus/Whereabouts fallback manifests in `_offline_assets/` from upstream sources. | (none) |
| `update_static_ip.sh` | Stamps the provided IP into managed `_common` manifests and static cluster IP values in QoS files, then hides those files from git tracking. | `<ip>` to set, `--undo` to restore placeholders and tracking |

> **Warning:** `update_static_ip.sh` rewrites the managed manifests under `_common/` and the static cluster IP values in the QoS XML files, then marks those files with `git skip-worktree` so they are hidden from git staging. Do **not** commit them after running this script as they contain a machine-specific IP address that will break deployments for other users. Run `./_scripts/update_static_ip.sh --undo` to restore placeholders and git tracking before editing or committing those files.

### Pod Debugging

| Script | Purpose | Options |
|--------|---------|----------|
| `describe.sh` | Shows pod details or network interfaces. | `-i` (interfaces only) |
| `exec.sh` | Opens a shell or runs `tcpdump` in a pod. | `-t` (tcpdump mode) |
| `get_logs.sh` | Displays the last 100 lines of pod logs. | (none) |
| `restart_pods.sh` | Restarts one or more pods. | (none) |

## Offline Deployment

Use the offline guide for when network access might not be available:

- [`_offline_assets/README.md`](_offline_assets/README.md)

Apply those steps after completing the Quick Start flow.

The offline guide includes:

- Environment prerequisites
- `deploy_pods.sh` behavior in offline mode
- Required images and mirror workflow
- Local manifest refresh guidance

## Prerequisites

Before deploying the K3s DDS environment, ensure the following requirements are met:

### System Requirements

- **RTI Connext DDS 7.3+** installed on the build host, with target libraries for all architectures you intend to deploy (e.g. `x64Linux4gcc7.3.0`, `armv8Linux4gcc7.3.0`). The host installation is required to build the Shapes source.
- **Docker** installed on nodes used to build images. Follow [official Docker installation guide](https://docs.docker.com/engine/install/).
- **Local container registry** available to store and pull images used by the cluster.
- **Kubernetes components** are installed by `./_scripts/deploy_node.sh` (K3s distribution + `kubectl`).
- **Network connectivity** between nodes for multi-node deployments

## Quick Start

### 1. Create Local Registry & Build Images

Set your cluster registry endpoint:
```bash
export STATIC_CLUSTER_IP=<static_cluster_ip>
```

Start a local registry:
```bash
docker run -d -p 5000:5000 --restart=always --name local-registry registry:2
```

Configure Docker to trust the local registry by copying `_example/template_daemon.json` to `/etc/docker/daemon.json` and replacing the placeholder with your static cluster IP:

```bash
sudo cp _example/template_daemon.json /etc/docker/daemon.json
sudo sed -i "s|<static_cluster_ip>|${STATIC_CLUSTER_IP}|g" /etc/docker/daemon.json
sudo systemctl restart docker
```

Set up a Docker Buildx builder with network access to the local registry:
```bash
docker buildx create --driver-opt network=host --use
```

From the repository root, build and push `shapes_multi_arch`:
```bash
docker buildx build --platform linux/amd64,linux/arm64 --push -t ${STATIC_CLUSTER_IP}:5000/shapes_multi_arch -f containers/shapes/Dockerfile .
```

From `containers/routing_service`, build and push `rs_multi_arch`:
```bash
docker buildx build --platform linux/amd64,linux/arm64 --push -t ${STATIC_CLUSTER_IP}:5000/rs_multi_arch -f Dockerfile .
```

From `containers/cds`, build and push `cds_latest`:
```bash
docker build --push -t ${STATIC_CLUSTER_IP}:5000/cds_latest .
```

Build and push the required CNI plugins assets image:
```bash
./_scripts/build_cni_plugins_assets_image.sh -m ${STATIC_CLUSTER_IP}:5000
```

This image is required by the `cni-plugins-installer` DaemonSet (used by Multus/MACVLAN deployment modes).

Once images are uploaded, verify the local registry catalog:
```bash
curl http://${STATIC_CLUSTER_IP}:5000/v2/_catalog
```

Note: If you need to change or rebuild the Shapes application binaries, see `containers/cross_compile/README.md` for cross-compilation container build/run steps.

### 2. Configure Static Network Interface (recommended)

For reliable multi-node deployments it is strongly recommended to assign static IP addresses to all nodes before installing K3s. This prevents cluster communication from breaking if DHCP assigns a different IP after a reboot.

> **Important:** The following files all depend on the cluster IP:
>
> - `_example/template_registries.yaml` — registry mirror config installed to each node by `deploy_node.sh`
> - `_common/` — deployment manifests
> - `containers/routing_service/qos/USER_ROUTING_SERVICE.xml` — Routing Service QoS profile
> - `_example/external_app_qos/USER_QOS_PROFILES.xml` — external app QoS profile (NodePort initial peer)

An example Netplan configuration is provided at `_example/01-netconfig.yaml`. Copy and adapt it on each node, and use the same interface name across the local control-plane and remote worker nodes. Deployment-specific guides describe this interface requirement in more detail (see [`docs/deployment-guides/mode-3-macvlan-all-pods.md`](docs/deployment-guides/mode-3-macvlan-all-pods.md) for an example).

```bash
# Edit the example to match your interface name, MAC address, and desired static IP
sudo cp _example/01-netconfig.yaml /etc/netplan/01-netconfig.yaml
sudo nano /etc/netplan/01-netconfig.yaml

# Apply the configuration
sudo netplan apply
```

Repeat on every remote worker node before running `deploy_node.sh`.

### 3. Setup K3s Cluster

**First Node (Control Plane):**
```bash
./_scripts/deploy_node.sh -c <control_plane_ip>

# To use Flannel CNI instead of Antrea (default):
./_scripts/deploy_node.sh -c <control_plane_ip> -n flannel
```

**Additional Nodes (Worker Nodes):**
```bash
# Remote worker - using ssh keys
./_scripts/deploy_node.sh -r <remote_node_ip> -u ubuntu

# Remote worker - optionally pass cluster ip (will try to auto-detect)
./_scripts/deploy_node.sh -r <remote_node_ip> -u ubuntu -c <control_plane_ip>

# Remote worker - using password
./_scripts/deploy_node.sh -r <remote_node_ip> -u ubuntu -p mypassword

```

### 4. Configure Shared Manifests and QoS Files

Stamp the control-plane IP into the managed manifests under `_common/` and the QoS files that still require a static cluster IP:

```bash
./_scripts/update_static_ip.sh <control_plane_ip>
```

If you need to edit or commit those files later, restore placeholders and git tracking with:

```bash
./_scripts/update_static_ip.sh --undo
```

### 5. Deploy Applications

Choose a deployment mode from the [Deployment Modes](#deployment-modes) table and deploy:

```bash
./_scripts/deploy_pods.sh -m <mode>  # Replace <mode> with 1-7
```

`deploy_pods.sh` integrates cleanup for existing deployments. To switch deployment modes (or redeploy the same mode after config changes), run `deploy_pods.sh` again with the desired mode.

Note: Some deployment modes require additional setup. See the [Scenario Guides](#scenario-guides) above for mode-specific prerequisites and steps.

### 6. Manage & Debug

```bash
# View pod details
./_scripts/describe.sh

# Check pod logs
./_scripts/get_logs.sh

# Execute commands in a pod
./_scripts/exec.sh

# Restart pods if needed
./_scripts/restart_pods.sh
```

### 7. Cleanup

```bash
# Selective deletion
./_scripts/delete_resources.sh

# Complete deployment cleanup
./_scripts/clean.sh
```

## Configuration

### QoS

- QoS files used in each pod are mounted and accessible on the host at `/opt/shapes/qos`. This directory is shared by all pods on that node. After modifying a QoS file, restart the affected pod(s) for the changes to take effect:

```bash
./_scripts/restart_pods.sh
```
