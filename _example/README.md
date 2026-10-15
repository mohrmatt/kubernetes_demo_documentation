# Example Configuration Files

This directory contains non-Kubernetes host-level configuration examples used during cluster setup.

The registry template in this directory (`template_registries.yaml`) is rendered automatically by `_scripts/deploy_node.sh` for both control-plane and remote worker installs.

## Files and Usage

### `01-netconfig.yaml`
- Purpose: Example Netplan configuration for a static interface/IP.
- Used when: Preparing control-plane and remote worker nodes with stable networking before running `deploy_node.sh`.
- Notes: Update interface name, MAC address, and IP settings to match each host.

### `k3s_config.yaml`
- Purpose: Example K3s server configuration with optional feature disables and networking settings.
- Used when: You want to customize K3s behavior beyond defaults.
- Notes: This is a reference template; apply values appropriate to your environment.

### `template_registries.yaml`
- Purpose: K3s registry mirror template for both control-plane and remote worker nodes.
- Used when: Installing or reinstalling nodes via `_scripts/deploy_node.sh`.
- Notes: Automatically processed by `_scripts/deploy_node.sh`; `<REGISTRY_IP_ADDRESS>` is replaced with the control-plane IP, then installed to `/etc/rancher/k3s/registries.yaml` on the target node.

### `template_daemon.json`
- Purpose: Docker daemon configuration template that adds the local registry as an insecure registry, allowing Docker to push and pull images over plain HTTP.
- Used when: Setting up the build host (control-plane node) with a local container registry before building and pushing images.
- Notes:
	- Copy to `/etc/docker/daemon.json` and replace `<static_cluster_ip>` with the control-plane IP, then restart Docker:
	  ```bash
	  sudo cp _example/template_daemon.json /etc/docker/daemon.json
	  sudo sed -i "s|<static_cluster_ip>|<control_plane_ip>|g" /etc/docker/daemon.json
	  sudo systemctl restart docker
	  ```
	- Without this file in place, Docker will refuse to push images to the local registry.

### `external_app_qos/USER_QOS_PROFILES.xml`
- Purpose: QoS profile for external DDS applications that connect to cluster workloads through Routing Service NodePort.
- Used when: Running deployment mode 7 and starting DDS applications outside the cluster.
- Notes:
	- Import this QoS file into Shapes Demo (or place it in the working directory of your external DDS app build).
	- The profile uses `UDPv4_WAN` and sets the Routing Service NodePort address as an initial peer (`node-ip:node-port`).
	- `_scripts/update_static_ip.sh <control_plane_ip>` updates this file automatically to match your environment.
