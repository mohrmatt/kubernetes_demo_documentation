# Mode 3: MACVLAN on All Pods

### Flannel

![Mode 3 - MACVLAN on All Pods (Flannel)](../deployment-slides/03-mode-3-macvlan-all-pods-flannel.png)

### Antrea

![Mode 3 - MACVLAN on All Pods (Antrea)](../deployment-slides/03-mode-3-macvlan-all-pods-antrea.png)

## Description

This mode attaches all app pods to a MACVLAN network via Multus.

**Multus** is a CNI plugin that enables adding secondary network interfaces to a pod, in addition to the default cluster interface. **Whereabouts** manages IP address allocation across all of those secondary interfaces cluster-wide, ensuring each pod on any node gets a unique IP.

This configuration is particularly useful for DDS applications because the MACVLAN interface binds directly to the host's physical network interface, making multicast traffic work as it would on a regular network — without the restrictions imposed by the default CNI overlay.

**Important network behavior to be aware of:**

- Applications running directly on the host of a node **cannot** communicate with pods on that same node using MACVLAN. This is a known limitation of how MACVLAN works at the Linux kernel level. It may appear to work in some cases because traffic falls back over another interface, but this should not be relied upon.
- Applications running outside the cluster on a **different** node are able to communicate with pods inside the cluster over the MACVLAN interface. For example, if an application is running on the host of Node B, it will be able to communicate with applications running inside the cluster on Nodes A and C.

## Prerequisites

Before deploying, ensure each node has a static network interface configured with a fixed IP address. Using a consistent interface name across all nodes is required for MACVLAN to function correctly. See [Network Prerequisites](../../README.md#network-prerequisites) for details.

**Interface name consistency is especially important here.** When Multus creates the MACVLAN network attachment, it looks up a specific interface name on the host. If the interface name differs between nodes, the network attachment will fail to bind on nodes where the name does not match.

Before deploying, update the `master` field in `_network_attachments/macvlan-whereabouts-config.yml` to match the interface name configured on your nodes (default is `eth0`):

```yaml
"master": "eth0"
```

If nodes use different interface names, separate network attachment configs would be required per node, removing the automation this setup provides.

This mode also requires the CNI plugins assets image used by the `cni-plugins-installer` DaemonSet. Build and push it before deployment:

```bash
./_scripts/build_cni_plugins_assets_image.sh -m <mirror_registry>
```

For example:

```bash
./_scripts/build_cni_plugins_assets_image.sh -m ${STATIC_CLUSTER_IP}:5000
```

## Steps

1. Deploy mode 3 (automatically installs Multus/Whereabouts and network attachment if needed):
   ```bash
   ./_scripts/deploy_pods.sh -m 3
   ```
2. Verify pods and network attachments:
   ```bash
   kubectl get pods -o wide
   kubectl get net-attach-def
   ```
3. Verify samples are being received/printed in pod logs:
   ```bash
   ./_scripts/get_logs.sh
   ```

## Manifests used

- `_common/pub/overlays/macvlan/` (BLUE on control-plane, randomly assigned color on remote workers)
- `_common/sub/overlays/macvlan/`

## Notes

- Mode 3 behavior is the same with either Antrea or Flannel as the base CNI.