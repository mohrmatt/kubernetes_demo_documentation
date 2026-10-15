#!/bin/bash

#
# K3s Node Deployment Script
# Deploys and configures k3s control plane or remote worker nodes.
# Antrea is the default CNI for local control-plane installs.
#
# Prerequisites: curl, sudo access, SSH keys or sshpass (for remote with password)
#

set -o pipefail

############################################################
# Constants & Global Variables
############################################################
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
NODE_TOKEN_PATH="/var/lib/rancher/k3s/server/node-token"
SERVER_TOKEN_PATH="/var/lib/rancher/k3s/server/token"
K3S_AGENT_DIR="/var/lib/rancher/k3s/agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANTREA_DIR="$ROOT_DIR/_antrea"
ANTREA_MANIFEST_URL="https://raw.githubusercontent.com/antrea-io/antrea/main/build/yamls/antrea.yml"

ANTREA_ROLLOUT_TIMEOUT="180s"
LOCAL_NODE_REGISTRATION_RETRIES=60
LOCAL_NODE_REGISTRATION_SLEEP_SECONDS=5
REMOTE_HOSTNAME_RETRIES=5
REMOTE_HOSTNAME_SLEEP_SECONDS=2
REMOTE_NODE_LABEL_RETRIES=30
REMOTE_NODE_LABEL_SLEEP_SECONDS=2
REMOTE_NODE_JOIN_WAIT_SECONDS=10
FLANNEL_IP_ALIGNMENT_RETRIES=30
FLANNEL_IP_ALIGNMENT_SLEEP_SECONDS=2

CONTROL_PLANE_IP=""
JOIN_TOKEN=""
REMOTE_NODE_IP=""
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PASSWORD=""
LOCAL_NODE_NAME=""
REMOTE_DETECTED_HOSTNAME=""
DESIRED_CNI="antrea"
PAUSE_IMAGE_TAG="rancher/mirrored-pause:3.6"
FLANNEL_IFACE=""
CNI_EXPLICIT="false"

############################################################
# Generic Helpers
############################################################
die() {
	echo "Error: $*" >&2
	exit 1
}

log() {
	echo "$*"
}

retry_until_success() {
	local attempts="$1"
	local sleep_seconds="$2"
	local wait_message="$3"
	shift 3

	local i
	for ((i=1; i<=attempts; i++)); do
		if "$@"; then
			return 0
		fi
		if [ "$i" -lt "$attempts" ]; then
			log "$wait_message ($i/$attempts)"
			sleep "$sleep_seconds"
		fi
	done
	return 1
}

usage() {
	cat <<EOF
Usage: $0 [-c IP] [-r HOST] [-u USER] [-p PASSWORD] [-n CNI] [-i IFACE]

Options:
  -c IP           Control plane IP (auto-detected if not specified)
  -r HOST         Remote host IP/hostname (enables remote worker mode)
  -u USER         Remote host username (required with -r)
  -p PASSWORD     Remote host password (optional, uses SSH keys if omitted)
	-n CNI          CNI type: antrea or flannel (default: antrea)
	-i IFACE        Flannel interface to use on this node (optional, Flannel only)

Examples:
  Control plane:        $0
  Control plane flannel:$0 -n flannel
	Control plane pinned: $0 -n flannel -i eth0
  Remote worker:        $0 -r 192.168.1.101 -u ubuntu -c 192.168.1.100
	Remote pinned:        $0 -r 192.168.1.101 -u ubuntu -n flannel -i eth0
  Remote worker:        $0 -r 192.168.1.101 -u ubuntu
  Remote with password: $0 -r 192.168.1.101 -u ubuntu -p mypassword
EOF
	exit 1
}

validate_cni_selection() {
	case "$DESIRED_CNI" in
		antrea|flannel) ;;
		*) die "Invalid CNI '$DESIRED_CNI'. Valid values: antrea, flannel" ;;
	esac

	if [ -n "$FLANNEL_IFACE" ] && [ "$DESIRED_CNI" != "flannel" ]; then
		log "Warning: -i/FLANNEL_IFACE is ignored unless -n flannel is selected"
	fi
}

detect_cluster_cni() {
	if kubectl get nodes -o yaml 2>/dev/null | grep -q 'flannel.alpha.coreos.com/backend-type'; then
		echo "flannel"
		return 0
	fi

	if kubectl get daemonset antrea-agent -n kube-system >/dev/null 2>&1 && \
	   kubectl get deployment antrea-controller -n kube-system >/dev/null 2>&1; then
		echo "antrea"
		return 0
	fi

	echo "antrea"
}

auto_select_remote_cni_if_unset() {
	[ -n "$REMOTE_HOST" ] || return 0
	[ "$CNI_EXPLICIT" = "true" ] && return 0

	DESIRED_CNI=$(detect_cluster_cni)
	log "Auto-detected cluster CNI for remote install: $DESIRED_CNI"
}

validate_local_flannel_iface() {
	[ -n "$REMOTE_HOST" ] && return 0
	[ "$DESIRED_CNI" = "flannel" ] || return 0
	[ -n "$FLANNEL_IFACE" ] || return 0
	ip link show "$FLANNEL_IFACE" >/dev/null 2>&1 || die "Flannel interface '$FLANNEL_IFACE' not found on local host"
}

remote_exec() {
	if [ -n "$REMOTE_PASSWORD" ]; then
		sshpass -p "$REMOTE_PASSWORD" ssh "$REMOTE_USER@$REMOTE_HOST" "$@"
	else
		ssh "$REMOTE_USER@$REMOTE_HOST" "$@"
	fi
}

remote_sudo() {
	local cmd="$1"
	local escaped_cmd
	escaped_cmd=$(printf "%q" "$cmd")

	if [ -n "$REMOTE_PASSWORD" ]; then
		local escaped_password
		escaped_password=$(printf "%q" "$REMOTE_PASSWORD")
		remote_exec "printf '%s\\n' $escaped_password | sudo -S -p '' sh -c $escaped_cmd"
	else
		remote_exec "sudo -n sh -c $escaped_cmd"
	fi
}

remote_scp_to() {
	local src="$1"
	local dst="$2"
	if [ -n "$REMOTE_PASSWORD" ]; then
		sshpass -p "$REMOTE_PASSWORD" scp -q "$src" "$REMOTE_USER@$REMOTE_HOST:$dst"
	else
		scp -q "$src" "$REMOTE_USER@$REMOTE_HOST:$dst"
	fi
}

############################################################
# Detection Helpers
############################################################
detect_control_plane_ip() {
	kubectl get nodes -o wide --no-headers 2>/dev/null | grep "control-plane\|master" | awk '{print $6}' | head -n1
}

detect_any_node_ip() {
	kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{print $6}' | head -n1
}

detect_local_primary_ip() {
	local detected_ip

	# Prefer the source IP selected by the kernel routing table.
	detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
	if [ -n "$detected_ip" ]; then
		echo "$detected_ip"
		return 0
	fi

	# Fallback for environments where `ip route get` is unavailable.
	hostname -I 2>/dev/null | awk '{print $1}'
}

detect_local_iface_for_ip() {
	local ip="$1"
	[ -n "$ip" ] || return 1
	ip -o -4 addr show scope global 2>/dev/null \
		| awk -v target="$ip" '{split($4,a,"/"); if (a[1] == target) {print $2; exit}}'
}

detect_remote_iface_for_ip() {
	local ip="$1"
	[ -n "$ip" ] || return 1
	remote_exec "ip -o -4 addr show scope global | awk -v target='$ip' '{split(\$4,a,\"/\"); if (a[1] == target) {print \$2; exit}}'" 2>/dev/null
}

detect_join_token() {
	if sudo test -f "$SERVER_TOKEN_PATH"; then
		sudo cat "$SERVER_TOKEN_PATH" | tr -d '\r\n'
		return 0
	fi

	if sudo test -f "$NODE_TOKEN_PATH"; then
		sudo cat "$NODE_TOKEN_PATH" | tr -d '\r\n'
		return 0
	fi

	return 1
}

normalize_join_token() {
	local token="$1"
	local ca_cert=""
	local ca_hash=""

	# Already secure token format (contains CA hash + credentials).
	if [[ "$token" == *"::"* ]]; then
		echo "$token"
		return 0
	fi

	# Convert short token into secure token when possible.
	if sudo test -f /var/lib/rancher/k3s/server/tls/server-ca.crt; then
		ca_cert="/var/lib/rancher/k3s/server/tls/server-ca.crt"
	elif sudo test -f /var/lib/rancher/k3s/agent/server-ca.crt; then
		ca_cert="/var/lib/rancher/k3s/agent/server-ca.crt"
	fi

	[ -n "$ca_cert" ] || { echo "$token"; return 0; }

	ca_hash=$(sudo sha256sum "$ca_cert" | awk '{print $1}')
	[ -n "$ca_hash" ] || { echo "$token"; return 0; }

	echo "K10${ca_hash}::server:${token}"
}

is_ipv4() {
	local ip="$1"
	local IFS=.
	local -a octets

	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	read -r -a octets <<< "$ip"
	[ "${#octets[@]}" -eq 4 ] || return 1

	local octet
	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9]+$ ]] || return 1
		[ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
	done

	return 0
}

ip_to_int() {
	local ip="$1"
	local o1 o2 o3 o4
	local IFS=.

	read -r o1 o2 o3 o4 <<< "$ip" || return 1
	echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

cidr_contains_ip() {
	local cidr="$1"
	local ip="$2"
	local net bits
	local net_int ip_int mask

	IFS=/ read -r net bits <<< "$cidr"
	is_ipv4 "$net" || return 1
	is_ipv4 "$ip" || return 1
	[[ "$bits" =~ ^[0-9]+$ ]] || return 1
	[ "$bits" -ge 0 ] && [ "$bits" -le 32 ] || return 1

	net_int=$(ip_to_int "$net") || return 1
	ip_int=$(ip_to_int "$ip") || return 1

	if [ "$bits" -eq 0 ]; then
		mask=0
	else
		mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
	fi

	[ $(( net_int & mask )) -eq $(( ip_int & mask )) ]
}

detect_remote_node_ip() {
	local cp_ip="$1"
	local remote_cidrs=()
	local remote_ips=()
	local cidr
	local remote_ip
	local subnet_prefix
	local resolved_remote_host_ip

	# Prefer interface CIDRs from the remote node and check whether the control-plane
	# IP belongs to any remote interface network.
	mapfile -t remote_cidrs < <(
		remote_exec "ip -o -4 addr show scope global | awk '{print \\$4}'" 2>/dev/null | sed '/^$/d'
	)

	for cidr in "${remote_cidrs[@]}"; do
		remote_ip="${cidr%%/*}"
		if cidr_contains_ip "$cidr" "$cp_ip"; then
			echo "$remote_ip"
			return 0
		fi
	done

	subnet_prefix=$(echo "$cp_ip" | awk -F. 'NF==4 {print $1"."$2"."$3"."}')

	mapfile -t remote_ips < <(
		remote_exec "hostname -I" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | sed '/^$/d'
	)

	# Legacy fallback: if control plane looks /24-like, keep previous behavior.
	if [ -n "$subnet_prefix" ]; then
		for remote_ip in "${remote_ips[@]}"; do
			if [[ "$remote_ip" == ${subnet_prefix}* ]]; then
				echo "$remote_ip"
				return 0
			fi
		done
	fi

	# If the user passed an IPv4 host directly, trust it as a practical fallback.
	if is_ipv4 "$REMOTE_HOST"; then
		for remote_ip in "${remote_ips[@]}"; do
			if [ "$remote_ip" = "$REMOTE_HOST" ]; then
				echo "$remote_ip"
				return 0
			fi
		done

		echo "$REMOTE_HOST"
		return 0
	fi

	resolved_remote_host_ip=$(getent ahostsv4 "$REMOTE_HOST" 2>/dev/null | awk 'NR==1 {print $1}')
	if is_ipv4 "$resolved_remote_host_ip"; then
		for remote_ip in "${remote_ips[@]}"; do
			if [ "$remote_ip" = "$resolved_remote_host_ip" ]; then
				echo "$remote_ip"
				return 0
			fi
		done

		if [ -n "$resolved_remote_host_ip" ]; then
			echo "$resolved_remote_host_ip"
			return 0
		fi
	fi

	if [ "${#remote_ips[@]}" -eq 1 ]; then
		echo "${remote_ips[0]}"
		return 0
	fi

	return 1
}

detect_local_node_name() {
	local candidate
	local node_name

	for candidate in "$(hostname 2>/dev/null)" "$(hostname -f 2>/dev/null)"; do
		[ -z "$candidate" ] && continue
		if kubectl get node "$candidate" &>/dev/null; then
			node_name=$(kubectl get node "$candidate" -o jsonpath='{.metadata.name}' 2>/dev/null)
			[ -n "$node_name" ] && echo "$node_name" && return 0
		fi
	done

	for candidate in $(hostname -I 2>/dev/null); do
		node_name=$(kubectl get nodes -o wide --no-headers 2>/dev/null | awk -v ip="$candidate" '$6 == ip {print $1; exit}')
		if [ -n "$node_name" ]; then
			echo "$node_name"
			return 0
		fi
	done
}

is_control_plane_node() {
	local node_name="$1"
	[ -z "$node_name" ] && return 1
	kubectl get node "$node_name" --show-labels --no-headers 2>/dev/null | grep -q 'node-role.kubernetes.io/\(control-plane\|master\)'
}

############################################################
# CNI Cleanup Helpers
############################################################
cleanup_cluster_cni_resources() {
	local target_cni="$1"

	if ! command -v kubectl >/dev/null 2>&1; then
		return 0
	fi
	if ! kubectl get nodes --no-headers >/dev/null 2>&1; then
		return 0
	fi

	log "Running cluster CNI cleanup for target: $target_cni"

	if [ "$target_cni" = "antrea" ]; then
		kubectl -n kube-system delete daemonset kube-flannel-ds --ignore-not-found >/dev/null 2>&1 || true
		kubectl -n kube-system delete configmap kube-flannel-cfg --ignore-not-found >/dev/null 2>&1 || true
		kubectl -n kube-system delete serviceaccount flannel --ignore-not-found >/dev/null 2>&1 || true
		kubectl delete clusterrole flannel --ignore-not-found >/dev/null 2>&1 || true
		kubectl delete clusterrolebinding flannel --ignore-not-found >/dev/null 2>&1 || true
	else
		kubectl -n kube-system delete daemonset antrea-agent --ignore-not-found >/dev/null 2>&1 || true
		kubectl -n kube-system delete deployment antrea-controller --ignore-not-found >/dev/null 2>&1 || true
		kubectl -n kube-system delete service antrea --ignore-not-found >/dev/null 2>&1 || true
		kubectl -n kube-system delete service antrea-metrics --ignore-not-found >/dev/null 2>&1 || true
		kubectl delete crd $(kubectl get crd -o name 2>/dev/null | grep '\.crd\.antrea\.io$' || true) --ignore-not-found >/dev/null 2>&1 || true
	fi
}

cleanup_local_cni_artifacts() {
	log "Cleaning up all old CNI artifacts (they will be replaced by cluster's configured CNI)"

	sudo mkdir -p /etc/cni/net.d /var/lib/cni /var/lib/rancher/k3s/agent/etc/cni || die "Failed to create CNI directories"

	# Clean all possible old CNI configs regardless of which one was used before
	sudo find /etc/cni/net.d -maxdepth 1 -type f \
		\( -name '*flannel*' -o -name '*10-flannel.conflist' -o -name '*antrea*' -o -name '*10-antrea*' \) \
		-delete 2>/dev/null || true
	sudo find /var/lib/rancher/k3s/agent/etc/cni/net.d -maxdepth 1 -type f \
		\( -name '*flannel*' -o -name '*10-flannel.conflist' -o -name '*antrea*' -o -name '*10-antrea*' \) \
		-delete 2>/dev/null || true

	# Remove any flannel runtime state
	sudo rm -rf /run/flannel 2>/dev/null || true

	# Clean up known network interfaces from various CNI implementations.
	# Then do a pattern-based pass to catch leftovers such as cni1/cni2.
	sudo ip link set cni0 down 2>/dev/null || true
	sudo ip link delete cni0 2>/dev/null || true
	sudo ip link set flannel.1 down 2>/dev/null || true
	sudo ip link delete flannel.1 2>/dev/null || true
	sudo ip link set antrea-gw0 down 2>/dev/null || true
	sudo ip link delete antrea-gw0 2>/dev/null || true
	sudo ip link set antrea-tun0 down 2>/dev/null || true
	sudo ip link delete antrea-tun0 2>/dev/null || true
	sudo ip link set genev_sys_6081 down 2>/dev/null || true
	sudo ip link delete genev_sys_6081 2>/dev/null || true

	while IFS= read -r stale_link; do
		[ -z "$stale_link" ] && continue
		sudo ip link set "$stale_link" down 2>/dev/null || true
		sudo ip link delete "$stale_link" 2>/dev/null || true
	done < <(
		sudo ip -o link show 2>/dev/null \
			| awk -F': ' '{print $2}' \
			| sed 's/@.*//' \
			| grep -E '^(cni[0-9]+|flannel\.[0-9]+|antrea-.+|genev_sys_6081)$' || true
	)

	# Antrea uses OVS (typically br-int); remove stale bridges/ports when tools are available.
	if command -v ovs-vsctl >/dev/null 2>&1; then
		sudo ovs-vsctl --if-exists del-br br-int >/dev/null 2>&1 || true
		sudo ovs-vsctl --if-exists del-br br-antrea >/dev/null 2>&1 || true
	fi

	# Always clear stale CNI state to avoid duplicate IP assignment after a CNI switch.
	sudo rm -rf /var/lib/cni/* 2>/dev/null || true
	sudo rm -rf /var/lib/rancher/k3s/agent/etc/cni/net.d 2>/dev/null || true
	sudo rm -rf /var/lib/antrea /etc/antrea /var/run/antrea 2>/dev/null || true

	# Remove old CNI plugin binaries that may be leftover from previous deployments
	# These include antrea, cilium, calico, weave, etc. - only keep bridge, host-local, portmap, loopback from cni-plugins
	if [ -d /opt/cni/bin ]; then
		sudo find /opt/cni/bin -maxdepth 1 -type f \
			\( -name 'antrea' -o -name 'antrea-cni' -o -name 'cilium' -o -name 'calico*' -o -name 'weave*' -o -name 'kube-subnet-mgr' \) \
			-delete 2>/dev/null || true
	fi

	# Clean K3s-specific CNI paths
	sudo rm -rf /var/lib/rancher/k3s/data/cni 2>/dev/null || true
}

cleanup_remote_cni_artifacts() {
	log "Cleaning up all old CNI artifacts on remote node (they will be replaced by cluster's configured CNI)"

	remote_sudo "mkdir -p /etc/cni/net.d /var/lib/cni /var/lib/rancher/k3s/agent/etc/cni" || die "Failed to create remote CNI directories"

	# Clean all possible old CNI configs regardless of which one was used before
	remote_sudo "find /etc/cni/net.d -maxdepth 1 -type f \\( -name '*flannel*' -o -name '*10-flannel.conflist' -o -name '*antrea*' -o -name '*10-antrea*' \\) -delete 2>/dev/null || true"
	remote_sudo "find /var/lib/rancher/k3s/agent/etc/cni/net.d -maxdepth 1 -type f \\( -name '*flannel*' -o -name '*10-flannel.conflist' -o -name '*antrea*' -o -name '*10-antrea*' \\) -delete 2>/dev/null || true"

	# Remove any flannel runtime state
	remote_sudo "rm -rf /run/flannel 2>/dev/null || true"

	# Clean up known network interfaces from various CNI implementations.
	# Then do a pattern-based pass to catch leftovers such as cni1/cni2.
	remote_sudo "ip link set cni0 down 2>/dev/null || true"
	remote_sudo "ip link delete cni0 2>/dev/null || true"
	remote_sudo "ip link set flannel.1 down 2>/dev/null || true"
	remote_sudo "ip link delete flannel.1 2>/dev/null || true"
	remote_sudo "ip link set antrea-gw0 down 2>/dev/null || true"
	remote_sudo "ip link delete antrea-gw0 2>/dev/null || true"
	remote_sudo "ip link set antrea-tun0 down 2>/dev/null || true"
	remote_sudo "ip link delete antrea-tun0 2>/dev/null || true"
	remote_sudo "ip link set genev_sys_6081 down 2>/dev/null || true"
	remote_sudo "ip link delete genev_sys_6081 2>/dev/null || true"
	remote_sudo "for stale_link in \$(ip -o link show 2>/dev/null | awk -F': ' '{print \$2}' | sed 's/@.*//' | grep -E '^(cni[0-9]+|flannel\\.[0-9]+|antrea-.+|genev_sys_6081)$' || true); do ip link set \"\$stale_link\" down 2>/dev/null || true; ip link delete \"\$stale_link\" 2>/dev/null || true; done"

	# Antrea uses OVS (typically br-int); remove stale bridges/ports when tools are available.
	remote_sudo "if command -v ovs-vsctl >/dev/null 2>&1; then ovs-vsctl --if-exists del-br br-int >/dev/null 2>&1 || true; ovs-vsctl --if-exists del-br br-antrea >/dev/null 2>&1 || true; fi"

	remote_sudo "rm -rf /var/lib/cni/* 2>/dev/null || true"
	remote_sudo "rm -rf /var/lib/rancher/k3s/agent/etc/cni/net.d 2>/dev/null || true"
	remote_sudo "rm -rf /var/lib/antrea /etc/antrea /var/run/antrea 2>/dev/null || true"

	# Remove old CNI plugin binaries that may be leftover from previous deployments
	remote_sudo "find /opt/cni/bin -maxdepth 1 -type f \\( -name 'antrea' -o -name 'antrea-cni' -o -name 'cilium' -o -name 'calico*' -o -name 'weave*' -o -name 'kube-subnet-mgr' \\) -delete 2>/dev/null || true"

	# Clean K3s-specific CNI paths
	remote_sudo "rm -rf /var/lib/rancher/k3s/data/cni 2>/dev/null || true"
}

cleanup_local_existing_install() {
	log "Checking for existing local k3s installation..."
	if sudo test -d /var/lib/rancher/k3s/server || sudo test -x /usr/local/bin/k3s-uninstall.sh; then
		log "Removing existing local k3s installation..."
		sudo test -x /usr/local/bin/k3s-uninstall.sh && sudo /usr/local/bin/k3s-uninstall.sh || true
		sudo systemctl stop k3s 2>/dev/null || true
		sudo systemctl stop k3s-agent 2>/dev/null || true
		sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s 2>/dev/null || true
		log "Existing local k3s installation removed"
	fi
}

############################################################
# Shared Registry and Local Control-Plane Helpers
############################################################
render_registry_config() {
	local registry_ip="$1"
	local output_path="$2"

	[ -z "$registry_ip" ] && die "Registry IP is required to render registries.yaml"
	[ ! -f "$ROOT_DIR/_example/template_registries.yaml" ] && die "Missing template registries file: $ROOT_DIR/_example/template_registries.yaml"

	sed "s/<REGISTRY_IP_ADDRESS>/$registry_ip/g" "$ROOT_DIR/_example/template_registries.yaml" > "$output_path" || die "Failed to render registries.yaml"
}

resolve_local_control_plane_ip() {
	if [ -z "$CONTROL_PLANE_IP" ]; then
		CONTROL_PLANE_IP=$(detect_local_primary_ip)
	fi
	[ -z "$CONTROL_PLANE_IP" ] && die "Could not determine control plane IP for local registry configuration"
}

get_local_pause_image() {
	[ -z "$CONTROL_PLANE_IP" ] && die "Control plane IP is required to resolve pause image"
	echo "${CONTROL_PLANE_IP}:5000/${PAUSE_IMAGE_TAG}"
}

configure_local_registry() {
	local temp_registries
	local local_registries_path="/etc/rancher/k3s/registries.yaml"

	resolve_local_control_plane_ip
	log "Rendering local registries.yaml with control plane IP: $CONTROL_PLANE_IP"
	temp_registries=$(mktemp)
	render_registry_config "$CONTROL_PLANE_IP" "$temp_registries"

	sudo mkdir -p /etc/rancher/k3s || die "Failed to create /etc/rancher/k3s"
	sudo cp "$temp_registries" "$local_registries_path" || die "Failed to install registries.yaml"
	rm -f "$temp_registries"
	log "Installed $local_registries_path"
}

install_local_control_plane() {
	log "Installing k3s..."
	resolve_local_control_plane_ip
	local pause_image
	pause_image="$(get_local_pause_image)"
	local flannel_iface_arg=""
	if [ "$DESIRED_CNI" = "flannel" ] && [ -z "$FLANNEL_IFACE" ]; then
		FLANNEL_IFACE=$(detect_local_iface_for_ip "$CONTROL_PLANE_IP")
		[ -n "$FLANNEL_IFACE" ] || die "Could not auto-detect local flannel interface for node IP $CONTROL_PLANE_IP; use -i IFACE"
		log "Auto-detected local flannel interface: $FLANNEL_IFACE (from node IP $CONTROL_PLANE_IP)"
	fi
	if [ "$DESIRED_CNI" = "flannel" ] && [ -n "$FLANNEL_IFACE" ]; then
		flannel_iface_arg=" --flannel-iface $FLANNEL_IFACE"
		log "Flannel interface pinned on local control-plane: $FLANNEL_IFACE"
	fi

	local install_exec
	if [ "$DESIRED_CNI" = "antrea" ]; then
		if [ -n "$CONTROL_PLANE_IP" ]; then
			install_exec="server --node-ip $CONTROL_PLANE_IP --advertise-address $CONTROL_PLANE_IP --tls-san $CONTROL_PLANE_IP --disable servicelb --disable traefik --disable coredns --disable metrics-server --disable local-storage --flannel-backend=none --disable-network-policy --kubelet-arg pod-infra-container-image=${pause_image}"
		else
			install_exec="server --disable servicelb --disable traefik --disable coredns --disable metrics-server --disable local-storage --flannel-backend=none --disable-network-policy --kubelet-arg pod-infra-container-image=${pause_image}"
		fi
	else
		if [ -n "$CONTROL_PLANE_IP" ]; then
			install_exec="server --node-ip $CONTROL_PLANE_IP --advertise-address $CONTROL_PLANE_IP --tls-san $CONTROL_PLANE_IP --disable servicelb --disable traefik --disable coredns --disable metrics-server --disable local-storage --kubelet-arg pod-infra-container-image=${pause_image}${flannel_iface_arg}"
		else
			install_exec="server --disable servicelb --disable traefik --disable coredns --disable metrics-server --disable local-storage --kubelet-arg pod-infra-container-image=${pause_image}${flannel_iface_arg}"
		fi
	fi

	if ! curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$install_exec" sh -s -; then
		die "Failed to download or install k3s control plane from https://get.k3s.io"
	fi
}

setup_local_kubeconfig() {
	log "Setting up kubeconfig..."
	mkdir -p ~/.kube
	sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 2>/dev/null || true
	sleep 2
}

wait_for_local_node_registration() {
	check_local_node_registration() {
		LOCAL_NODE_NAME=$(detect_local_node_name)
		[ -n "$LOCAL_NODE_NAME" ] && kubectl get node "$LOCAL_NODE_NAME" &>/dev/null
	}

	log "Waiting for local node to be registered in the Kubernetes API..."
	retry_until_success \
		"$LOCAL_NODE_REGISTRATION_RETRIES" \
		"$LOCAL_NODE_REGISTRATION_SLEEP_SECONDS" \
		"Waiting for node registration..." \
		check_local_node_registration || return 1

	log "Node is registered: $LOCAL_NODE_NAME"
	return 0
}

label_local_control_plane() {
	local node_name="$1"
	local label_type="local"

	[ -z "$node_name" ] && die "Could not determine the local Kubernetes node name"
	is_control_plane_node "$node_name" || die "Refusing to apply app-type=$label_type to non-control-plane node: $node_name"
	kubectl label nodes "$node_name" app-type=$label_type --overwrite || die "Failed to apply app-type=$label_type to $node_name"
	kubectl label nodes "$node_name" shapes/color=BLUE --overwrite || die "Failed to apply shapes/color=BLUE to $node_name"
	log "Label applied: app-type=$label_type, shapes/color=BLUE"
}

# Assign a unique publisher color to a node from the available (non-BLUE) pool.
# Picks randomly; falls back to RED if all colors are exhausted.
assign_publisher_color() {
	local node_name="$1"
	local all_colors=(RED GREEN YELLOW ORANGE PURPLE CYAN MAGENTA)
	local used_colors
	local color

	# Collect colors already assigned across all nodes (handles 'shapes/color' key with slash)
	used_colors=$(kubectl get nodes -o go-template='{{range .items}}{{index .metadata.labels "shapes/color"}} {{end}}' 2>/dev/null)

	# Shuffle and pick the first unused color
	while IFS= read -r color; do
		if ! echo " $used_colors " | grep -qw "$color"; then
			kubectl label node "$node_name" "shapes/color=$color" --overwrite || return 1
			log "Publisher color assigned: $color → $node_name"
			return 0
		fi
	done < <(printf '%s\n' "${all_colors[@]}" | shuf)

	# Fallback if all colors are already in use
	kubectl label node "$node_name" shapes/color=RED --overwrite || true
	log "Warning: All unique colors in use. Assigned RED as fallback to $node_name"
}

ensure_cni_symlink() {
	local k3s_cni_parent="/var/lib/rancher/k3s/agent/etc/cni"
	local k3s_cni_d="$k3s_cni_parent/net.d"
	local cni_net_d="/etc/cni/net.d"
	local current_target

	log "Creating CNI symlink..."
	sudo mkdir -p "$k3s_cni_parent" "$(dirname "$cni_net_d")"

	if sudo test -L "$k3s_cni_d"; then
		current_target=$(sudo readlink "$k3s_cni_d" 2>/dev/null || true)
		if [ "$current_target" = "$cni_net_d" ]; then
			log "Symlink already exists"
			return
		fi
		sudo rm -f "$k3s_cni_d" || die "Failed to remove existing CNI symlink"
		sudo ln -s -T "$cni_net_d" "$k3s_cni_d" && log "Symlink updated" || die "Symlink creation failed"
	elif sudo test -e "$k3s_cni_d"; then
		if sudo test -d "$k3s_cni_d"; then
			log "$k3s_cni_d exists as a directory; migrating files to $cni_net_d before symlink"
			sudo mkdir -p "$cni_net_d" || die "Failed to create $cni_net_d"
			sudo cp -a "$k3s_cni_d"/. "$cni_net_d"/ || die "Failed to migrate CNI files to $cni_net_d"
		else
			log "$k3s_cni_d exists and is not a symlink; replacing it"
		fi
		sudo rm -rf "$k3s_cni_d" || die "Failed to remove $k3s_cni_d"
		sudo ln -s -T "$cni_net_d" "$k3s_cni_d" && log "Symlink created" || die "Symlink creation failed"
	else
		sudo ln -s -T "$cni_net_d" "$k3s_cni_d" && log "Symlink created" || die "Symlink creation failed"
	fi
}

ensure_remote_cni_symlink() {
	local k3s_cni_parent="/var/lib/rancher/k3s/agent/etc/cni"
	local k3s_cni_d="$k3s_cni_parent/net.d"
	local cni_net_d="/etc/cni/net.d"

	log "Creating CNI symlink on remote node..."
	remote_sudo "mkdir -p '$k3s_cni_parent' \"\$(dirname '$cni_net_d')\"" || die "Failed to create remote CNI parent directories"

	if remote_sudo "test -L '$k3s_cni_d'"; then
		local current_target
		current_target=$(remote_sudo "readlink '$k3s_cni_d'" 2>/dev/null || true)
		if [ "$current_target" = "$cni_net_d" ]; then
			log "Remote CNI symlink already exists"
			return
		fi
		remote_sudo "rm -f '$k3s_cni_d'" || die "Failed to remove existing remote CNI symlink"
		remote_sudo "ln -s -T '$cni_net_d' '$k3s_cni_d'" && log "Remote CNI symlink updated" || die "Remote CNI symlink creation failed"
	elif remote_sudo "test -e '$k3s_cni_d'"; then
		if remote_sudo "test -d '$k3s_cni_d'"; then
			log "Remote $k3s_cni_d exists as a directory; migrating files to $cni_net_d before symlink"
			remote_sudo "mkdir -p '$cni_net_d'" || die "Failed to create remote $cni_net_d"
			remote_sudo "cp -a '$k3s_cni_d/.' '$cni_net_d/'" || die "Failed to migrate remote CNI files to $cni_net_d"
		else
			log "Remote $k3s_cni_d exists and is not a symlink; replacing it"
		fi
		remote_sudo "rm -rf '$k3s_cni_d'" || die "Failed to remove remote $k3s_cni_d"
		remote_sudo "ln -s -T '$cni_net_d' '$k3s_cni_d'" && log "Remote CNI symlink created" || die "Remote CNI symlink creation failed"
	else
		remote_sudo "ln -s -T '$cni_net_d' '$k3s_cni_d'" && log "Remote CNI symlink created" || die "Remote CNI symlink creation failed"
	fi
}


deploy_antrea_cni() {
	if kubectl get daemonset antrea-agent -n kube-system &>/dev/null && \
	   kubectl get deployment antrea-controller -n kube-system &>/dev/null; then
		log "Antrea is already deployed, skipping deployment..."
		log "Verifying Antrea rollout status..."
		kubectl rollout status daemonset antrea-agent -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea agent DaemonSet rollout did not complete"
		kubectl rollout status deployment antrea-controller -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea controller Deployment rollout did not complete"
		log "Verifying Antrea pods are ready..."
		kubectl wait --for=condition=ready pod -l app=antrea,component=antrea-agent -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea agent pods are not ready"
		kubectl wait --for=condition=ready pod -l app=antrea,component=antrea-controller -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea controller pods are not ready"
		log "Antrea pods are ready."
		return
	fi

	log "Deploying Antrea CNI..."
	mkdir -p "$ANTREA_DIR"
	rm -f "$ANTREA_DIR"/antrea.yaml
	curl -sfL "$ANTREA_MANIFEST_URL" -o "$ANTREA_DIR/antrea.yaml" || die "Failed to download Antrea manifest from $ANTREA_MANIFEST_URL"

	# Antrea defaults to in-cluster service IP (10.43.0.1) which is unreachable
	# on host-networked pods when the kube-proxy datapath is not yet established.
	# Override both agent and controller configs to reach the API server directly.
	if [ -n "$CONTROL_PLANE_IP" ]; then
		sed -i "s|kubeAPIServerOverride: \"\"|kubeAPIServerOverride: \"https://$CONTROL_PLANE_IP:6443\"|g" "$ANTREA_DIR/antrea.yaml" \
			|| die "Failed to patch kubeAPIServerOverride in Antrea manifest"
		log "Patched Antrea kubeAPIServerOverride -> https://$CONTROL_PLANE_IP:6443"
	fi

	kubectl apply -f "$ANTREA_DIR/antrea.yaml" || die "Failed to apply Antrea manifest"

	log "Waiting for Antrea rollout status..."
	kubectl rollout status daemonset antrea-agent -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea agent DaemonSet rollout did not complete"
	kubectl rollout status deployment antrea-controller -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea controller Deployment rollout did not complete"

	log "Waiting for Antrea pods to be ready..."
	kubectl wait --for=condition=ready pod -l app=antrea,component=antrea-agent -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea agent pods failed to become ready"
	kubectl wait --for=condition=ready pod -l app=antrea,component=antrea-controller -n kube-system --timeout="$ANTREA_ROLLOUT_TIMEOUT" || die "Antrea controller pods failed to become ready"
	log "Antrea pods are ready."
}

run_local_control_plane_install() {
	local node_name

	log "=== Control Plane Installation ==="
	cleanup_cluster_cni_resources "$DESIRED_CNI"
	cleanup_local_existing_install
	cleanup_local_cni_artifacts
	configure_local_registry
	install_local_control_plane
	setup_local_kubeconfig

	wait_for_local_node_registration || die "Timeout: Local node did not register in Kubernetes API"
	node_name="$LOCAL_NODE_NAME"
	label_local_control_plane "$node_name"

	ensure_cni_symlink
	if [ "$DESIRED_CNI" = "antrea" ]; then
		deploy_antrea_cni
	else
		log "Flannel selected; skipping Antrea deployment"
	fi

	log ""
	log "Installation complete!"
	log "Node: $node_name"
	log "kubectl get nodes"
}

############################################################
# Remote Worker Helpers
############################################################
validate_remote_args() {
	[ -z "$REMOTE_USER" ] && die "Remote host (-r) requires username (-u)"
	if [ -n "$REMOTE_PASSWORD" ]; then
		command -v sshpass &>/dev/null || die "sshpass required for password auth. Install: sudo apt-get install sshpass"
	fi

	remote_exec "true" >/dev/null 2>&1 || die "Unable to connect to remote host: $REMOTE_USER@$REMOTE_HOST"
	remote_sudo "true" >/dev/null 2>&1 || die "Remote sudo check failed for $REMOTE_USER@$REMOTE_HOST. Ensure this user has sudo privileges, and use -p with the sudo password (or configure passwordless sudo)."

	if [ "$DESIRED_CNI" = "flannel" ] && [ -n "$FLANNEL_IFACE" ]; then
		remote_exec "ip link show '$FLANNEL_IFACE' >/dev/null 2>&1" || die "Flannel interface '$FLANNEL_IFACE' not found on remote host"
	fi
}

detect_remote_install_settings() {
	log "Auto-detecting control plane IP..."
	if [ -z "$CONTROL_PLANE_IP" ]; then
		CONTROL_PLANE_IP=$(detect_control_plane_ip)
		[ -z "$CONTROL_PLANE_IP" ] && CONTROL_PLANE_IP=$(detect_any_node_ip)
		[ -z "$CONTROL_PLANE_IP" ] && CONTROL_PLANE_IP=$(hostname -I | awk '{print $1}')
	fi
	log "Control plane IP: $CONTROL_PLANE_IP"

	log "Retrieving join token..."
	JOIN_TOKEN=$(detect_join_token) || die "Cannot find join token at $SERVER_TOKEN_PATH or $NODE_TOKEN_PATH"
	JOIN_TOKEN=$(normalize_join_token "$JOIN_TOKEN")
	log "Token: [retrieved]"
	if [[ "$JOIN_TOKEN" != *"::"* ]]; then
		log "Warning: token does not appear to be a secure K3s token (missing CA hash prefix). TLS bootstrap may fail against self-signed control-plane certs."
	fi

	log "Detecting remote worker IP on control plane subnet..."
	REMOTE_NODE_IP=$(detect_remote_node_ip "$CONTROL_PLANE_IP") || die "Could not determine a usable remote node IPv4 address (control plane: $CONTROL_PLANE_IP, remote host: $REMOTE_HOST)"
	log "Remote worker IP: $REMOTE_NODE_IP"

	if [ "$DESIRED_CNI" = "flannel" ] && [ -z "$FLANNEL_IFACE" ]; then
		FLANNEL_IFACE=$(detect_remote_iface_for_ip "$REMOTE_NODE_IP")
		[ -n "$FLANNEL_IFACE" ] || die "Could not auto-detect remote flannel interface for worker IP $REMOTE_NODE_IP; use -i IFACE"
		log "Auto-detected remote flannel interface: $FLANNEL_IFACE (from worker IP $REMOTE_NODE_IP)"
	fi

	# If this worker IP previously joined, remove stale node object so
	# server-side node password state does not block rejoin.
	cleanup_stale_remote_node_on_server "$REMOTE_NODE_IP"

	[ -z "$CONTROL_PLANE_IP" ] || [ -z "$JOIN_TOKEN" ] || [ -z "$REMOTE_NODE_IP" ] && die "Missing control plane IP, token, or remote worker IP"
}

cleanup_stale_remote_node_on_server() {
	local remote_ip="$1"
	local stale_nodes

	stale_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}={.address}{","}{end}{"\n"}{end}' 2>/dev/null \
		| awk -F'\t' -v ip="$remote_ip" '$2 ~ ("(^|,)(InternalIP|ExternalIP)=" ip "(,|$)") {print $1}')

	if [ -z "$stale_nodes" ]; then
		return 0
	fi

	log "Removing stale node object(s) for worker IP $remote_ip:"
	printf "%s\n" "$stale_nodes" | while IFS= read -r node; do
		[ -z "$node" ] && continue
		if is_control_plane_node "$node"; then
			log "Skipping control-plane node '$node' during stale worker cleanup"
			continue
		fi
		kubectl delete node "$node" --ignore-not-found >/dev/null 2>&1 || true
		log "Deleted stale node '$node'"
	done
}

preflight_remote_control_plane_connectivity() {
	log "Preflight: validating remote connectivity to control-plane API..."

	# This endpoint is required for agent TLS bootstrap; failure here means join cannot succeed.
	if remote_exec "curl -kfsS --connect-timeout 5 --max-time 12 https://$CONTROL_PLANE_IP:6443/cacerts >/dev/null"; then
		log "Preflight OK: remote host can reach https://$CONTROL_PLANE_IP:6443/cacerts"
		return 0
	fi

	log "Preflight failed: remote host cannot fetch https://$CONTROL_PLANE_IP:6443/cacerts"
	log "Remote diagnostics (connectivity/path):"
	remote_exec "ip -4 route get $CONTROL_PLANE_IP 2>/dev/null || true"
	remote_exec "curl -vk --connect-timeout 5 --max-time 12 https://$CONTROL_PLANE_IP:6443/cacerts 2>&1 | tail -n 40 || true"
	log "Control-plane diagnostics (listener/path):"
	sudo ss -lntp | awk 'NR==1 || /:6443/' || true
	die "Control-plane API is not reachable from remote host on TCP 6443. Check host firewall/security groups, routing, and API listener binding before retrying."
}

configure_remote_registry() {
	local temp_registries
	local remote_registries_path="/etc/rancher/k3s/registries.yaml"
	local remote_temp_path="/tmp/registries.yaml"

	log "Configuring K3s registry on remote node..."
	log "Rendering remote registries.yaml with control plane IP: $CONTROL_PLANE_IP..."
	temp_registries=$(mktemp)
	render_registry_config "$CONTROL_PLANE_IP" "$temp_registries"

	remote_scp_to "$temp_registries" "$remote_temp_path" || die "Failed to copy registries.yaml to remote node"
	remote_sudo "mkdir -p /etc/rancher/k3s && mv $remote_temp_path $remote_registries_path" || die "Failed to install registries.yaml on remote node"
	remote_sudo "test -s $remote_registries_path" || die "Remote registries.yaml was not created correctly"
	rm -f "$temp_registries"
	log "Installed $remote_registries_path on remote node"
}

cleanup_remote_existing_install() {
	log "Checking for existing k3s installation..."
	log "Removing existing installation..."

	# Prefer the official uninstall script when present.
	remote_sudo "test -x /usr/local/bin/k3s-agent-uninstall.sh && /usr/local/bin/k3s-agent-uninstall.sh || true"
	remote_sudo "test -x /usr/local/bin/k3s-uninstall.sh && /usr/local/bin/k3s-uninstall.sh || true"

	# Ensure services/processes are stopped in case uninstall script is missing or partial.
	remote_sudo "systemctl stop k3s-agent 2>/dev/null || true"
	remote_sudo "systemctl stop k3s 2>/dev/null || true"
	remote_sudo "pkill -f '(^|/)k3s( |$)' 2>/dev/null || true"

	# Unmount any nested mounts under the k3s data directory before removal.
	remote_sudo "grep \" /var/lib/rancher/k3s/agent\" /proc/self/mounts | cut -d\" \" -f2 | sort -r | xargs -r -n1 umount -l || true"
	remote_sudo "grep \" /var/lib/rancher/k3s\" /proc/self/mounts | cut -d\" \" -f2 | sort -r | xargs -r -n1 umount -l || true"

	# Retry removal because containerd state can linger briefly after service stop.
	local attempt
	for attempt in {1..5}; do
		if remote_sudo "rm -rf /var/lib/rancher/k3s /etc/rancher/k3s"; then
			break
		fi
		if [ "$attempt" -eq 5 ]; then
			die "Failed to remove existing installation"
		fi
		log "Retrying cleanup... ($attempt/5)"
		sleep 2
	done

	log "Cleanup complete"

	# Remove stale node password identity so rejoin does not fail with
	# 'Node password rejected' after reinstall/retry cycles.
	remote_sudo "rm -rf /etc/rancher/node" || true

	cleanup_remote_cni_artifacts
}

find_k3s_ca_cert() {
	# Search for k3s CA certificate in common locations.
	local ca_paths=(
		"/var/lib/rancher/k3s/agent/server-ca.crt"
		"/etc/rancher/k3s/server/ca.crt"
		"/var/lib/rancher/k3s/server/tls/server-ca.crt"
		"/var/lib/rancher/k3s/server/ca.crt"
		"/etc/rancher/k3s/ca.crt"
	)
	
	local path
	for path in "${ca_paths[@]}"; do
		if [ -f "$path" ]; then
			echo "$path"
			return 0
		fi
	done
	
	return 1
}

install_remote_worker() {
	local install_cmd
	local install_timeout_seconds=300
	local remote_install_log="/tmp/k3s-agent-install.log"
	local pause_image
	pause_image="$(get_local_pause_image)"
	local flannel_iface_arg=""
	if [ "$DESIRED_CNI" = "flannel" ] && [ -n "$FLANNEL_IFACE" ]; then
		flannel_iface_arg=" --flannel-iface $FLANNEL_IFACE"
		log "Flannel interface pinned on remote worker: $FLANNEL_IFACE"
	fi

	log "Installing k3s on remote host..."
	install_cmd="curl -sfL https://get.k3s.io | K3S_URL='https://$CONTROL_PLANE_IP:6443' K3S_TOKEN='$JOIN_TOKEN' INSTALL_K3S_EXEC='agent --node-ip $REMOTE_NODE_IP --with-node-id --kubelet-arg pod-infra-container-image=${pause_image}${flannel_iface_arg}' INSTALL_K3S_SKIP_SELINUX_RPM=true sh -"
	remote_sudo "rm -f $remote_install_log" || true

	if ! remote_sudo "timeout ${install_timeout_seconds}s sh -c \"$install_cmd\" > '$remote_install_log' 2>&1"; then
		log "Remote installation failed or timed out after ${install_timeout_seconds}s"
		log "Last installer output from remote host:"
		remote_sudo "tail -n 120 '$remote_install_log' || true"
		log "Collecting remote k3s-agent diagnostics..."
		remote_sudo "systemctl --no-pager -l status k3s-agent || true"
		remote_sudo "systemctl --no-pager -l status k3s || true"
		remote_sudo "journalctl --no-pager -u k3s-agent -n 120 || true"
		remote_sudo "journalctl --no-pager -u k3s -n 120 || true"
		remote_exec "ip -4 route get $CONTROL_PLANE_IP 2>/dev/null || true"
		die "Remote installation failed"
	fi
}

get_remote_hostname() {
	check_remote_hostname() {
		REMOTE_DETECTED_HOSTNAME=$(remote_exec "hostname" 2>/dev/null)
		[ -n "$REMOTE_DETECTED_HOSTNAME" ]
	}

	retry_until_success \
		"$REMOTE_HOSTNAME_RETRIES" \
		"$REMOTE_HOSTNAME_SLEEP_SECONDS" \
		"Retrying hostname retrieval..." \
		check_remote_hostname || return 1

	return 0
}

label_remote_node() {
	local remote_hostname="$1"
	local remote_ip="$REMOTE_NODE_IP"
	local resolved_node_name=""
	try_label_remote_node() {
		local target_node
		local normalized_hostname

		target_node=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}={.address}{","}{end}{"\n"}{end}' 2>/dev/null \
			| awk -F'\t' -v ip="$remote_ip" '$2 ~ ("(^|,)(InternalIP|ExternalIP)=" ip "(,|$)") {print $1; exit}')

		if [ -z "$target_node" ] && [ -n "$1" ]; then
			normalized_hostname=$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')
			if kubectl get node "$normalized_hostname" &>/dev/null; then
				target_node="$normalized_hostname"
			fi
		fi

		[ -z "$target_node" ] && return 1

		# Safety guard for environments where worker/control-plane hostnames collide.
		if is_control_plane_node "$target_node"; then
			log "Resolved node '$target_node' is control-plane; waiting for remote worker node registration"
			return 1
		fi

		resolved_node_name="$target_node"
		kubectl get node "$target_node" &>/dev/null && \
			kubectl label nodes "$target_node" app-type=remote --overwrite &>/dev/null
	}

	[ -z "$remote_hostname" ] && { log "Warning: Could not retrieve hostname"; return 0; }

	log "Labeling node: $remote_hostname"
	if retry_until_success \
		"$REMOTE_NODE_LABEL_RETRIES" \
		"$REMOTE_NODE_LABEL_SLEEP_SECONDS" \
		"Waiting for node..." \
		try_label_remote_node "$remote_hostname"; then
		log "Label applied: app-type=remote"
		if [ -n "$resolved_node_name" ]; then
			assign_publisher_color "$resolved_node_name"
		fi
		return 0
	fi

	log ""
	log "ERROR: Failed to label node"
	log "Manual: kubectl get nodes -o wide   # find worker by IP $remote_ip"
	log "Manual: kubectl label nodes <worker-node-name> app-type=remote --overwrite"
	log ""
	return 0
}

verify_remote_flannel_ip_alignment() {
	local remote_ip="$REMOTE_NODE_IP"
	local resolved_node_name=""
	local internal_ip=""
	local flannel_public_ip=""

	[ "$DESIRED_CNI" = "flannel" ] || return 0

	check_flannel_alignment() {
		resolved_node_name=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}={.address}{","}{end}{"\n"}{end}' 2>/dev/null \
			| awk -F'\t' -v ip="$remote_ip" '$2 ~ ("(^|,)(InternalIP|ExternalIP)=" ip "(,|$)") {print $1; exit}')

		[ -n "$resolved_node_name" ] || return 1

		internal_ip=$(kubectl get node "$resolved_node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
		flannel_public_ip=$(kubectl get node "$resolved_node_name" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}' 2>/dev/null)

		[ -n "$internal_ip" ] || return 1
		[ -n "$flannel_public_ip" ] || return 1
		[ "$internal_ip" = "$flannel_public_ip" ]
	}

	log "Verifying Flannel public-ip alignment on remote worker..."
	if retry_until_success \
		"$FLANNEL_IP_ALIGNMENT_RETRIES" \
		"$FLANNEL_IP_ALIGNMENT_SLEEP_SECONDS" \
		"Waiting for Flannel annotation alignment..." \
		check_flannel_alignment; then
		log "Flannel annotation aligned on $resolved_node_name: public-ip=$flannel_public_ip internal-ip=$internal_ip"
		return 0
	fi

	log "ERROR: Flannel annotation mismatch on remote worker"
	log "Node: ${resolved_node_name:-unknown}"
	log "InternalIP: ${internal_ip:-missing}"
	log "Flannel public-ip: ${flannel_public_ip:-missing}"
	log "This usually means Flannel selected the wrong interface. Re-run with '-n flannel -i <iface>' or verify node IP/interface selection."
	die "Remote worker Flannel IP alignment check failed"
}

run_remote_worker_install() {
	local remote_hostname

	log "=== Remote Worker Installation ==="
	log "Remote host: $REMOTE_USER@$REMOTE_HOST"
	log "Auth: $([ -n "$REMOTE_PASSWORD" ] && echo "password" || echo "SSH keys")"

	detect_remote_install_settings
	preflight_remote_control_plane_connectivity
	cleanup_remote_existing_install
	configure_remote_registry
	install_remote_worker
	ensure_remote_cni_symlink

	log "Waiting for node to join cluster..."
	sleep "$REMOTE_NODE_JOIN_WAIT_SECONDS"

	log "Retrieving remote hostname..."
	if get_remote_hostname; then
		remote_hostname="$REMOTE_DETECTED_HOSTNAME"
	else
		remote_hostname=""
	fi
	label_remote_node "$remote_hostname"
	verify_remote_flannel_ip_alignment

	log ""
	log "Remote worker installation complete!"
	log "Run: kubectl get nodes"
}

############################################################
# Main
############################################################
while getopts "r:u:c:p:n:i:" OPT; do
	case "${OPT}" in
		c) CONTROL_PLANE_IP="$OPTARG" ;;
		r) REMOTE_HOST="$OPTARG" ;;
		u) REMOTE_USER="$OPTARG" ;;
		p) REMOTE_PASSWORD="$OPTARG" ;;
		n) DESIRED_CNI="$OPTARG"; CNI_EXPLICIT="true" ;;
		i) FLANNEL_IFACE="$OPTARG" ;;
		*) usage ;;
	esac
done

auto_select_remote_cni_if_unset
validate_cni_selection
validate_local_flannel_iface

if [ -n "$REMOTE_HOST" ]; then
	validate_remote_args
	run_remote_worker_install
	exit 0
fi

run_local_control_plane_install
