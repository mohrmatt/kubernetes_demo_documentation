# Offline Mode Deployment Assets

This directory provides local deployment manifests and operational guidance for running offline or network-restricted deployments.

Prerequisite: The Kubernetes cluster must already be deployed and reachable (for example via `./_scripts/deploy_node.sh`). Offline mode in this repository only applies to workload/pod deployment through `deploy_pods.sh`.

Repo-local CNI plugin archives are stored in `_offline_assets/cni-plugins/` and packaged into the `cni-plugins-assets` image consumed by `_helper_yaml/cni-plugins-installer.yaml`.

## Files & Source URLs

| File | Source URL | Purpose |
|------|-----------|---------|
| `multus-daemonset.yml` | `https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml` | Main Multus CNI plugin DaemonSet |
| `whereabouts-daemonset-install.yaml` | `https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/daemonset-install.yaml` | Whereabouts IPAM DaemonSet |
| `whereabouts-ippools-crd.yaml` | `https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_ippools.yaml` | Whereabouts IPPool CRD |
| `whereabouts-overlappingrangeipreservations-crd.yaml` | `https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml` | Whereabouts OverlappingRangeIPReservation CRD |

## When These Manifests Are Used

Offline manifests are deployed when:

1. **Explicit offline mode**: User runs `deploy_pods.sh -m MODE -o` (or `--offline`)
2. **Automatic fallback**: Remote Multus manifest download fails (network unreachable, GitHub down, etc.)

Modes that require Multus/Whereabouts:
- **Mode 3**: MACVLAN on all pods
- **Mode 4**: MACVLAN on routing service only
- **Mode 6**: Routing Service to cloud ⚠️ *Not permitted in offline mode because it requires external connectivity to communicate with cloud DDS applications*

## Refreshing Manifests

Use the repository refresh script:

```bash
./_scripts/refresh_offline_assets.sh
```

The script refreshes:
- `_offline_assets/multus-daemonset.yml`
- `_offline_assets/whereabouts-daemonset-install.yaml`
- `_offline_assets/whereabouts-ippools-crd.yaml`
- `_offline_assets/whereabouts-overlappingrangeipreservations-crd.yaml`

## Container Images Required

The list below includes images referenced by:
- `_common/**/*.yaml` (workloads)
- `_offline_assets/*.yaml` (Multus/Whereabouts)
- `_helper_yaml/*.yaml` (CNI helper DaemonSets)

Mirror all offline-required images with one command:

```bash
./_scripts/mirror_offline_images.sh -m <static_cluster_ip>:5000
```

By default, the script removes local image tags after successful pushes. To keep local tags for reuse/debugging:

```bash
./_scripts/mirror_offline_images.sh -m <static_cluster_ip>:5000 --keep-local
```

The script pulls, tags, and pushes all required images from `_common`, `_offline_assets`, and `_helper_yaml` references.

### CNI plugins assets image (required)

Build and push the `cni-plugins-assets` image to your local mirror:

```bash
./_scripts/build_cni_plugins_assets_image.sh -m <static_cluster_ip>:5000
```

This image bundles the offline archives from `_offline_assets/cni-plugins/` and is referenced by `cni-plugins-installer` as `docker.io/library/cni-plugins-assets:v1.4.0` (pulled via your configured `docker.io` mirror).

### Project images from `_common` manifests

These are already mirror-prefixed in `_common` and must exist in your mirror:
- `<static_cluster_ip>:5000/shapes_multi_arch`
- `<static_cluster_ip>:5000/rs_multi_arch`
- `<static_cluster_ip>:5000/cds_latest`

Build and push them directly to your static cluster registry:

```bash
# shapes_multi_arch
docker buildx build --platform linux/amd64,linux/arm64 --push -t <static_cluster_ip>:5000/shapes_multi_arch -f containers/shapes/Dockerfile .

# rs_multi_arch
docker buildx build --platform linux/amd64,linux/arm64 --push -t <static_cluster_ip>:5000/rs_multi_arch -f containers/routing_service/Dockerfile containers/routing_service

# cds_latest
docker build --push -t <static_cluster_ip>:5000/cds_latest containers/cds
```

### Optional quick check (all required images)

```bash
docker pull "$MIRROR/shapes_multi_arch" && \
docker pull "$MIRROR/rs_multi_arch" && \
docker pull "$MIRROR/cds_latest" && \
docker pull "$MIRROR/multus-cni:snapshot" && \
docker pull "$MIRROR/whereabouts:latest" && \
docker pull "$MIRROR/kubectl:latest" && \
docker pull "$MIRROR/busybox:1.36" && \
docker pull "$MIRROR/alpine:latest" && \
docker pull "$MIRROR/library/cni-plugins-assets:v1.4.0" && \
docker pull "$MIRROR/pause:3.6" && \
docker pull "$MIRROR/rancher/mirrored-pause:3.6" && \
docker pull "$MIRROR/antrea/antrea-agent-ubuntu:latest" && \
docker pull "$MIRROR/antrea/antrea-controller-ubuntu:latest"
```

## Usage Examples

### Deploy Mode 3 (MACVLAN everywhere) with offline manifests:
```bash
./deploy_pods.sh -m 3 -o
```

### Deploy Mode 4 (MACVLAN on routing service) with offline manifests:
```bash
./deploy_pods.sh -m 4 --offline
```

### Deploy Mode 1 normally (does not require offline manifests):
```bash
./deploy_pods.sh -m 1
```

### Attempt Mode 6 with offline flag (will fail as intended):
```bash
./deploy_pods.sh -m 6 -o
# Error: Mode 6 (Routing Service to cloud) is not supported in offline mode. Run without --offline.
```

## Notes

- **Version pinning**: These manifests currently track the `master` branch. For production, consider pinning to specific release versions by editing the source URLs.
- **Manifest validation**: After refreshing, verify manifests are valid YAML and review any breaking changes in upstream projects.
- **Auto-fallback**: The deploy script automatically switches from remote to local manifests if network access fails, so explicit offline mode is optional unless you want to enforce it.

