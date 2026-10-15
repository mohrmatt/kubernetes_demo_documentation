#!/bin/bash

#
# K3s Pod Deployment Script
# Deploys application pods with different CNI and networking configurations
#
# Usage: $0 -m MODE
# Options:
#   -m MODE: deployment mode (1-7, required)
#     1 = Default CNI (Antrea/Flannel) with multicast disabled
#     2 = Antrea CNI with multicast enabled
#     3 = MACVLAN on all pods
#     4 = MACVLAN on routing service pod only
#     5 = Cloud Discovery Service (CDS)
#     6 = Routing Service to cloud
#     7 = External to Pod with NodePort Service
#
# Prerequisites: kubectl configured and K3s cluster running
#
set -o pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Shared helpers (die, prompt utilities, etc.)
# shellcheck source=_scripts/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# Tracks the last successfully deployed mode across reboots
DEPLOY_MODE_STATE_FILE="$ROOT_DIR/.deploy_mode"

OFFLINE_ASSETS_DIR="$ROOT_DIR/_offline_assets"
MULTUS_REMOTE_MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml"
WHEREABOUTS_REMOTE_DAEMONSET_MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/daemonset-install.yaml"
WHEREABOUTS_REMOTE_IPPOOLS_MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_ippools.yaml"
WHEREABOUTS_REMOTE_OVERLAPPING_MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml"

MULTUS_LOCAL_MANIFEST="$OFFLINE_ASSETS_DIR/multus-daemonset.yml"
WHEREABOUTS_LOCAL_DAEMONSET_MANIFEST="$OFFLINE_ASSETS_DIR/whereabouts-daemonset-install.yaml"
WHEREABOUTS_LOCAL_IPPOOLS_MANIFEST="$OFFLINE_ASSETS_DIR/whereabouts-ippools-crd.yaml"
WHEREABOUTS_LOCAL_OVERLAPPING_MANIFEST="$OFFLINE_ASSETS_DIR/whereabouts-overlappingrangeipreservations-crd.yaml"

# ---------------------------------------------------------------------------
# Whereabouts API server override
# ---------------------------------------------------------------------------
# Whereabouts uses in-cluster config by default (10.43.0.1), which is not
# reachable from host-networked pods until the datapath is fully established.
# Inject KUBERNETES_SERVICE_HOST/PORT so it dials the API server directly.

# Returns the control-plane IP from the kubernetes endpoint.
detect_api_server_ip() {
	kubectl get endpoints kubernetes -n default \
		-o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null
}

# Writes a patched copy of the Multus daemonset manifest with
# KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT injected into the
# kube-multus container so the generated kubeconfig points at the real
# API server IP instead of the ClusterIP (10.43.0.1).
patch_multus_manifest() {
	local src="$1"
	local api_ip
	api_ip="$(detect_api_server_ip)"

	if [ -z "$api_ip" ]; then
		echo "[deploy] Warning: could not detect API server IP; Multus will use in-cluster config" >&2
		echo "$src"
		return 0
	fi

	local tmp
	tmp="$(mktemp /tmp/multus-patched.XXXXXX.yaml)"

	# Inject env block after the last thin_entrypoint arg, which is unique to
	# the kube-multus container (initContainer uses /install_multus).
	sed 's|\(        - "--cni-conf-dir=/host/etc/cni/net.d"\)|\1\n        env:\n        - name: KUBERNETES_SERVICE_HOST\n          value: "'"${api_ip}"'"\n        - name: KUBERNETES_SERVICE_PORT\n          value: "6443"|' \
		"$src" > "$tmp"

	echo "[deploy] Patched Multus manifest: KUBERNETES_SERVICE_HOST=${api_ip} KUBERNETES_SERVICE_PORT=6443" >&2
	echo "$tmp"
}

# Writes a patched copy of the Whereabouts daemonset manifest with
# KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT injected, and
# prints the path to the temp file.
patch_whereabouts_manifest() {
	local src="$1"
	local api_ip
	api_ip="$(detect_api_server_ip)"

	if [ -z "$api_ip" ]; then
		echo "[deploy] Warning: could not detect API server IP; Whereabouts will use in-cluster config" >&2
		echo "$src"
		return 0
	fi

	local tmp
	tmp="$(mktemp /tmp/whereabouts-patched.XXXXXX.yaml)"

	# Inject env vars immediately after the existing WHEREABOUTS_NAMESPACE entry.
	sed "/fieldPath: metadata.namespace/{n; s|^|        - name: KUBERNETES_SERVICE_HOST\n          value: \"${api_ip}\"\n        - name: KUBERNETES_SERVICE_PORT\n          value: \"6443\"\n|;}" \
		"$src" > "$tmp"

	echo "[deploy] Patched Whereabouts manifest: KUBERNETES_SERVICE_HOST=${api_ip} KUBERNETES_SERVICE_PORT=6443" >&2
	echo "$tmp"
}

# Writes a patched copy of k3s-cni-path-linker with API server env vars
# injected into the configure-macvlan-promisc init container.
patch_k3s_cni_path_linker_manifest() {
	local src="$1"
	local api_ip
	api_ip="$(detect_api_server_ip)"

	if [ -z "$api_ip" ]; then
		echo "[deploy] Warning: could not detect API server IP; k3s-cni-path-linker will use in-cluster config" >&2
		echo "$src"
		return 0
	fi

	# Avoid duplicate env injection if manifest is already patched.
	if grep -q 'name: KUBERNETES_SERVICE_HOST' "$src"; then
		echo "$src"
		return 0
	fi

	local tmp
	tmp="$(mktemp /tmp/k3s-cni-path-linker-patched.XXXXXX.yaml)"

	# Inject env block after the kubectl image line (unique to configure-macvlan-promisc).
	awk -v api_ip="$api_ip" '
		{ print }
		/image: bitnami\/kubectl:latest/ {
			print "          env:"
			print "            - name: KUBERNETES_SERVICE_HOST"
			print "              value: \"" api_ip "\""
			print "            - name: KUBERNETES_SERVICE_PORT"
			print "              value: \"6443\""
		}
	' "$src" > "$tmp"

	echo "[deploy] Patched k3s-cni-path-linker manifest: KUBERNETES_SERVICE_HOST=${api_ip} KUBERNETES_SERVICE_PORT=6443" >&2
	echo "$tmp"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_section() { echo ""; echo "========== DEPLOY :: $1 =========="; }
log_step()    { echo "[deploy] $1"; }

# ---------------------------------------------------------------------------
# Usage / validation
# ---------------------------------------------------------------------------

usage() {
	echo "Usage: $0 [-m MODE] [-o|--offline]"
	echo -e "Options:\n\
	-m MODE: specify deployment mode (1-7, required)\n\
	-o, --offline: force offline mode using local Multus/Whereabouts manifests\n\
	              (automatic fallback occurs on remote download failure)\n\
	-h, --help: show this help message\n\
\n\
Modes:\n\
	1 = Using default CNI (Antrea/Flannel) with multicast disabled\n\
	2 = Using CNI Antrea with multicast enabled\n\
	3 = MACVLAN on all pods\n\
	4 = MACVLAN on routing service pod only\n\
	5 = CDS for internal discovery\n\
	6 = Routing Service to cloud\n\
	7 = External to Pod with Node Port Service\n\
\n\
Examples:\n\
	$0 -m 1                    # Deploy mode 1 (default CNI)\n\
	$0 -m 3 -o                 # Deploy mode 3 with offline Multus/Whereabouts\n\
	$0 -m 4 --offline          # Deploy mode 4 (offline alias)\n\
\n\
Note: Modes 3, 4, and 6 require Multus+Whereabouts. See _offline_assets/README.md for air-gapped deployment details."
	exit 1
}

preflight_checks() {
	log_section "PREFLIGHT"
	log_step "Validating kubectl availability"
	if ! command -v kubectl > /dev/null 2>&1; then
		die "kubectl is not installed or not in PATH."
	fi

	log_step "Validating Kubernetes API connectivity"
	if ! kubectl get nodes --no-headers > /dev/null 2>&1; then
		die "Unable to reach Kubernetes cluster with kubectl. Ensure kubeconfig is configured and the cluster is accessible."
	fi

	log_step "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Mode metadata helpers
# ---------------------------------------------------------------------------

# Human-readable label for a mode number
mode_label() {
	local cni_label
	cni_label=$(current_cni_label)

	case "$1" in
		1) echo "CNI $cni_label, multicast disabled" ;;
		2) echo "CNI $cni_label, multicast enabled"  ;;
		3) echo "MACVLAN on all pods (base CNI: $cni_label)" ;;
		4) echo "MACVLAN on routing service only (base CNI: $cni_label)" ;;
		5) echo "CDS for internal discovery (base CNI: $cni_label)" ;;
		6) echo "Routing Service to cloud (base CNI: $cni_label)" ;;
		7) echo "External via NodePort (base CNI: $cni_label)" ;;
	esac
}

current_cni_label() {
	if cluster_uses_antrea; then
		echo "Antrea"
		return
	fi

	if cluster_uses_flannel; then
		echo "Flannel"
		return
	fi

	echo "Unknown"
}

cluster_uses_antrea() {
       # Only return true if antrea-agent DaemonSet and antrea-controller Deployment are present and have available pods.
       if kubectl get daemonset antrea-agent -n kube-system -o jsonpath='{.status.numberAvailable}' 2>/dev/null | grep -q '^[1-9]'; then
	       if kubectl get deployment antrea-controller -n kube-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^[1-9]'; then
		       return 0
	       fi
       fi
       return 1
}

cluster_uses_flannel() {
	# K3s built-in Flannel may not create kube-flannel DaemonSet/ConfigMap objects.
	# Detect via node annotations and local CNI config files instead.
	if kubectl get nodes -o yaml 2>/dev/null | grep -q 'flannel.alpha.coreos.com/backend-type'; then
		return 0
	fi

	find /etc/cni/net.d -maxdepth 1 -type f -name '*flannel*' 2>/dev/null | grep -q .
}

validate_mode_cni_compatibility() {
	local mode="$1"

	if [ "$mode" = "2" ] && ! cluster_uses_antrea; then
		die "Mode 2 requires Antrea CNI. Reinstall nodes with Antrea (deploy_node.sh -n antrea), then retry mode 2."
	fi
}

# Infrastructure category -- modes in the same category share prerequisites
# and can be switched without a full cluster clean.
mode_category() {
	case "$1" in
		1|2) echo "cni"      ;; # _common/ kustomize base, no Multus
		3|4|6) echo "multus" ;; # Multus + MACVLAN infrastructure
		5) echo "cds"        ;; # Cloud Discovery Service
		7) echo "nodeport"   ;; # NodePort external access
	esac
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# Remove Shapes workloads first; run a full clean only when the infrastructure
# category changes (e.g. cni -> multus requires Multus teardown).
cleanup_if_needed() {
	local target_mode="$1"
	local target_cat
	target_cat=$(mode_category "$target_mode")

	log_section "CLEANUP"
	log_step "Target mode: $target_mode (category: $target_cat)"

	if [ -f "$DEPLOY_MODE_STATE_FILE" ]; then
		local prev_mode
		prev_mode=$(tr -cd '0-9' < "$DEPLOY_MODE_STATE_FILE")
		if [ -n "$prev_mode" ]; then
			log_step "Previous mode detected: $prev_mode"
			log_step "Running shapes-only cleanup"
			bash "$SCRIPT_DIR/clean.sh" --shapes-only

			local prev_cat
			prev_cat=$(mode_category "$prev_mode")
			if [ "$prev_cat" = "$target_cat" ]; then
				if [ "$prev_mode" = "$target_mode" ]; then
					log_step "Redeploying mode $target_mode - workloads and services torn down"
				else
					log_step "Mode $prev_mode is compatible with mode $target_mode - skipping full cleanup"
				fi
				return 0
			fi
			log_step "Mode switch requires full cleanup: $prev_mode ($prev_cat) -> $target_mode ($target_cat)"
		fi
	else
		local user_resource_count
		user_resource_count=$( (kubectl get deployments,statefulsets -A --no-headers 2>/dev/null | grep -v "^kube-system" || true) | wc -l)
		if [ "$user_resource_count" -eq 0 ]; then
			log_step "No previous user workloads detected - cleanup skipped"
			return 0
		fi
		log_step "Detected existing deployment - running full cleanup"
	fi

	bash "$SCRIPT_DIR/clean.sh"
	log_step "Cleanup phase complete"
}

# ---------------------------------------------------------------------------
# Antrea configuration
# ---------------------------------------------------------------------------

# Patch antrea-config to the desired multicast state.
# Always enforces tunnelType=vxlan.
set_antrea_multicast() {
	local desired="$1"
	local desired_tunnel_type="vxlan"

	# Inline sed/awk transforms applied as a pipeline over the config text

	update_feature_gate_multicast() {
		sed -E "s/^([[:space:]]*Multicast:[[:space:]]*)(true|false)([[:space:]]*)$/\\1${desired}\\3/"
	}

	update_multicast_enable() {
		awk -v desired_mc="$desired" '
			/^[[:space:]]*multicast:[[:space:]]*$/ { in_multicast = 1; print; next }
			in_multicast && /^[[:space:]]*enable:[[:space:]]*(true|false)[[:space:]]*$/ {
				sub(/(true|false)/, desired_mc); in_multicast = 0; print; next
			}
			in_multicast && /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*/ { in_multicast = 0 }
			{ print }
		'
	}

	update_tunnel_type() {
		sed -E "s/^([[:space:]]*tunnelType:[[:space:]]*).*/\\1\"${desired_tunnel_type}\"/"
	}

	local agent_conf controller_conf
	agent_conf=$(kubectl -n kube-system get configmap antrea-config -o jsonpath='{.data.antrea-agent\.conf}')
	controller_conf=$(kubectl -n kube-system get configmap antrea-config -o jsonpath='{.data.antrea-controller\.conf}')

	[ -z "$agent_conf" ]      && die "antrea-agent.conf not found in antrea-config"
	[ -z "$controller_conf" ] && die "antrea-controller.conf not found in antrea-config"

	local current_feature_gate current_multicast_enable current_tunnel_type
	current_feature_gate=$(printf "%s\n" "$controller_conf" | sed -nE 's/^[[:space:]]*Multicast:[[:space:]]*(true|false)[[:space:]]*$/\1/p' | head -n1)
	current_multicast_enable=$(printf "%s\n" "$agent_conf" | awk '
		/^[[:space:]]*multicast:[[:space:]]*$/ { in_multicast = 1; next }
		in_multicast && /^[[:space:]]*enable:[[:space:]]*(true|false)[[:space:]]*$/ {
			sub(/.*enable:[[:space:]]*/, ""); gsub(/[[:space:]]*/, ""); print; exit
		}
		in_multicast && /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*/ { in_multicast = 0 }
	')
	current_tunnel_type=$(printf "%s\n" "$agent_conf" | sed -nE 's/^[[:space:]]*tunnelType:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' | head -n1)

	if [ "$current_feature_gate"     = "$desired"             ] && \
	   [ "$current_multicast_enable" = "$desired"             ] && \
	   [ "$current_tunnel_type"      = "$desired_tunnel_type" ]; then
		log_step "Antrea config already at desired state - skipping patch"
		return 0
	fi

	local updated_agent_conf updated_controller_conf
	updated_agent_conf=$(printf "%s\n" "$agent_conf" \
		| update_feature_gate_multicast \
		| update_multicast_enable \
		| update_tunnel_type)
	updated_controller_conf=$(printf "%s\n" "$controller_conf" | update_feature_gate_multicast)

	if [ "$updated_agent_conf" = "$agent_conf" ] && [ "$updated_controller_conf" = "$controller_conf" ]; then
		log_step "Antrea rendered config unchanged - skipping patch and restart"
		return 0
	fi

	local patch_file
	patch_file=$(mktemp)
	{
		echo "data:"
		echo "  antrea-agent.conf: |"
		printf "%s\n" "$updated_agent_conf" | sed 's/^/    /'
		echo "  antrea-controller.conf: |"
		printf "%s\n" "$updated_controller_conf" | sed 's/^/    /'
	} > "$patch_file"

	kubectl -n kube-system patch configmap antrea-config --type merge --patch-file "$patch_file"
	rm -f "$patch_file"

	log_step "Restarting Antrea components..."
	kubectl -n kube-system rollout restart deployment antrea-controller
	kubectl -n kube-system rollout restart daemonset antrea-agent
	kubectl -n kube-system rollout status deployment antrea-controller --timeout=180s
	kubectl -n kube-system rollout status daemonset antrea-agent --timeout=180s
}

# ---------------------------------------------------------------------------
# Multus / MACVLAN infrastructure
# ---------------------------------------------------------------------------

ensure_daemonset() {
	local name="$1"
	local namespace="$2"
	local present_msg="$3"
	local absent_msg="$4"
	shift 4

	if kubectl get daemonset "$name" -n "$namespace" > /dev/null 2>&1; then
		log_step "$present_msg"
	else
		log_step "$absent_msg"
		"$@"
	fi
}

ensure_net_attach_def() {
	local name="$1"
	local present_msg="$2"
	local absent_msg="$3"
	local manifest="$4"

	if kubectl get net-attach-def "$name" > /dev/null 2>&1; then
		log_step "$present_msg"
	else
		log_step "$absent_msg"
		kubectl apply -f "$manifest"
	fi
}

deploy_multus_infrastructure() {
	local use_local_manifests="$OFFLINE_MODE"

	if [ "$use_local_manifests" = "true" ]; then
		log_step "Offline mode enabled: using local manifests from $OFFLINE_ASSETS_DIR"
	fi

	if kubectl get daemonset cni-plugins-installer -n kube-system > /dev/null 2>&1 && \
	   kubectl get daemonset k3s-cni-path-linker -n kube-system > /dev/null 2>&1; then
		log_step "CNI helper DaemonSets already deployed - reapplying to enforce latest config"
	else
		log_step "Applying CNI helper DaemonSets"
	fi

	local patched_linker
	patched_linker="$(patch_k3s_cni_path_linker_manifest "$ROOT_DIR/_helper_yaml/k3s-cni-path-linker.yaml")"
	kubectl apply -f "$ROOT_DIR/_helper_yaml/cni-plugins-installer.yaml" || die "Failed to apply cni-plugins-installer DaemonSet"
	kubectl apply -f "$patched_linker" || die "Failed to apply k3s-cni-path-linker DaemonSet"
	[ "$patched_linker" != "$ROOT_DIR/_helper_yaml/k3s-cni-path-linker.yaml" ] && rm -f "$patched_linker"

	if kubectl get daemonset kube-multus-ds -n kube-system > /dev/null 2>&1; then
		log_step "Multus already deployed - skipping"
	else
		log_step "Deploying Multus CNI"
		if [ "$use_local_manifests" = "true" ]; then
			[ -f "$MULTUS_LOCAL_MANIFEST" ] || die "Offline manifest missing: $MULTUS_LOCAL_MANIFEST"
			local patched_multus
			patched_multus="$(patch_multus_manifest "$MULTUS_LOCAL_MANIFEST")"
			kubectl apply -f "$patched_multus"
			[ "$patched_multus" != "$MULTUS_LOCAL_MANIFEST" ] && rm -f "$patched_multus"
		else
			local multus_remote_tmp
			multus_remote_tmp="$(mktemp /tmp/multus-remote.XXXXXX.yaml)"
			if ! curl -sfL "$MULTUS_REMOTE_MANIFEST" -o "$multus_remote_tmp"; then
				log_step "Remote Multus manifest download failed; switching to offline local manifests"
				rm -f "$multus_remote_tmp"
				[ -f "$MULTUS_LOCAL_MANIFEST" ] || die "Multus remote download failed and offline manifest missing: $MULTUS_LOCAL_MANIFEST"
				local patched_multus
				patched_multus="$(patch_multus_manifest "$MULTUS_LOCAL_MANIFEST")"
				kubectl apply -f "$patched_multus"
				[ "$patched_multus" != "$MULTUS_LOCAL_MANIFEST" ] && rm -f "$patched_multus"
				use_local_manifests="true"
			else
				local patched_multus
				patched_multus="$(patch_multus_manifest "$multus_remote_tmp")"
				kubectl apply -f "$patched_multus"
				rm -f "$multus_remote_tmp"
				[ "$patched_multus" != "$multus_remote_tmp" ] && rm -f "$patched_multus"
			fi
		fi

		log_step "Waiting for Multus pod to be ready..."
		if ! kubectl wait --for=condition=ready pod -l app=multus -n kube-system --timeout=300s; then
			die "Multus pod failed to become ready"
		fi
		log_step "Multus pod ready"
	fi

	if kubectl get daemonset whereabouts -n kube-system > /dev/null 2>&1; then
		log_step "Whereabouts already deployed - skipping"
	else
		log_step "Deploying Whereabouts"
		if [ "$use_local_manifests" = "true" ]; then
			[ -f "$WHEREABOUTS_LOCAL_DAEMONSET_MANIFEST" ] || die "Offline manifest missing: $WHEREABOUTS_LOCAL_DAEMONSET_MANIFEST"
			[ -f "$WHEREABOUTS_LOCAL_IPPOOLS_MANIFEST" ] || die "Offline manifest missing: $WHEREABOUTS_LOCAL_IPPOOLS_MANIFEST"
			[ -f "$WHEREABOUTS_LOCAL_OVERLAPPING_MANIFEST" ] || die "Offline manifest missing: $WHEREABOUTS_LOCAL_OVERLAPPING_MANIFEST"
			local patched_whereabouts
			patched_whereabouts="$(patch_whereabouts_manifest "$WHEREABOUTS_LOCAL_DAEMONSET_MANIFEST")"
			kubectl apply \
				-f "$patched_whereabouts" \
				-f "$WHEREABOUTS_LOCAL_IPPOOLS_MANIFEST" \
				-f "$WHEREABOUTS_LOCAL_OVERLAPPING_MANIFEST"
			[ "$patched_whereabouts" != "$WHEREABOUTS_LOCAL_DAEMONSET_MANIFEST" ] && rm -f "$patched_whereabouts"
		else
			local remote_tmp
			remote_tmp="$(mktemp /tmp/whereabouts-remote.XXXXXX.yaml)"
			curl -sfL "$WHEREABOUTS_REMOTE_DAEMONSET_MANIFEST" -o "$remote_tmp" \
				|| die "Failed to download Whereabouts daemonset manifest"
			local patched_whereabouts
			patched_whereabouts="$(patch_whereabouts_manifest "$remote_tmp")"
			kubectl apply \
				-f "$patched_whereabouts" \
				-f "$WHEREABOUTS_REMOTE_IPPOOLS_MANIFEST" \
				-f "$WHEREABOUTS_REMOTE_OVERLAPPING_MANIFEST"
			rm -f "$remote_tmp"
			[ "$patched_whereabouts" != "$remote_tmp" ] && rm -f "$patched_whereabouts"
		fi
	fi

	ensure_net_attach_def \
		"macvlan-config" \
		"MACVLAN NetworkAttachmentDefinition already exists - skipping" \
		"Creating MACVLAN NetworkAttachmentDefinition" \
		"$ROOT_DIR/_network_attachments/macvlan-whereabouts-config.yml"
}

# ---------------------------------------------------------------------------
# ConfigMap helpers
# ---------------------------------------------------------------------------

patch_configmap() {
	local name="$1" key="$2" value="$3"
	kubectl create configmap "$name" \
		--from-literal="$key=$value" \
		--dry-run=client -o yaml | kubectl apply -f -
}

routing_service_profile_for_mode() {
	local mode="$1"
	local cni_label

	cni_label=$(current_cni_label)

	case "$mode" in
		4)
			case "$cni_label" in
				Antrea) echo "InterfaceBridge_Antrea" ;;
				Flannel) echo "InterfaceBridge_Flannel" ;;
				*) die "Mode 4 requires a detected base CNI (Antrea/Flannel) to select a routing service profile" ;;
			esac
			;;
		6)
			case "$cni_label" in
				Antrea) echo "Shapes_Cloud_Demo_Antrea" ;;
				Flannel) echo "Shapes_Cloud_Demo_Flannel" ;;
				*) die "Mode 6 requires a detected base CNI (Antrea/Flannel) to select a routing service profile" ;;
			esac
			;;
		7)
			echo "Kubernetes_To_External"
			;;
		*)
			echo ""
			;;
	esac
}

mode_uses_cds() {
	local mode="$1"

	case "$mode" in
		5|7)
			return 0
			;;
		4|6)
			if cluster_uses_flannel; then
				return 1
			fi
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# Set all three workload ConfigMaps for the selected mode in one place.
configure_workload_configmaps() {
	local mode="$1"
	local sub_args="" pub_args="" rs_args=""
	local rs_profile=""
	local use_cds="false"

	if mode_uses_cds "$mode"; then
		use_cds="true"
	fi

	case "$mode" in
		3)     sub_args="--macvlan"; pub_args="--macvlan" ;;
		4|5|7)
			if [ "$use_cds" = "true" ]; then
				sub_args="--cds"
				pub_args="--cds"
			fi
			;;
		6)
			if [ "$use_cds" = "true" ]; then
				pub_args="--cds"
			fi
			;;
	esac

	rs_profile=$(routing_service_profile_for_mode "$mode")
	if [ -n "$rs_profile" ]; then
		rs_args="-c $rs_profile"
	fi

	log_step "Setting shapes-sub-config: SUBSCRIBER_ARGS='$sub_args'"
	patch_configmap shapes-sub-config SUBSCRIBER_ARGS "$sub_args"

	log_step "Setting shapes-pub-config: PUBLISHER_ARGS='$pub_args'"
	patch_configmap shapes-pub-config PUBLISHER_ARGS "$pub_args"

	log_step "Setting shapes-rs-config: ROUTING_SERVICE_ARGS='$rs_args'"
	patch_configmap shapes-rs-config ROUTING_SERVICE_ARGS "$rs_args"
}

# ---------------------------------------------------------------------------
# Manifest apply helpers
# ---------------------------------------------------------------------------

apply_pub() { log_step "Applying publisher ${1##*/}";       kubectl apply -k "$ROOT_DIR/_common/pub/$1"; }
apply_sub() { log_step "Applying subscriber ${1##*/}";      kubectl apply -k "$ROOT_DIR/_common/sub/$1"; }
apply_rs()  { log_step "Applying routing-service ${1##*/}"; kubectl apply -k "$ROOT_DIR/_common/rs/$1"; }

apply_cds() {
	log_step "Applying CDS resources"
	kubectl apply -f "$ROOT_DIR/_common/cds/"
	kubectl apply -f "$ROOT_DIR/_common/services/cluster_ip_service.yaml"
}

mode_requires_multus() {
	case "$1" in
		3|4|6) return 0 ;;
		*) return 1 ;;
	esac
}

mode_actions() {
	case "$1" in
		1|2) echo "pub_base sub_base" ;;
		3) echo "pub_macvlan sub_macvlan" ;;
		4) echo "pub_base sub_base rs_macvlan cds" ;;
		5) echo "pub_base sub_base cds" ;;
		6) echo "pub_base rs_macvlan cds" ;;
		7) echo "nodeport_service pub_base sub_base rs_nodeport cds" ;;
		*) die "Unsupported mode: $1" ;;
	esac
}

run_mode_actions() {
	local mode="$1"
	local action

	for action in $(mode_actions "$mode"); do
		case "$action" in
			pub_base) apply_pub base ;;
			sub_base) apply_sub base ;;
			pub_macvlan) apply_pub overlays/macvlan ;;
			sub_macvlan) apply_sub overlays/macvlan ;;
			rs_macvlan) apply_rs overlays/macvlan ;;
			rs_nodeport) apply_rs overlays/nodeport ;;
			cds)
				if mode_uses_cds "$mode"; then
					apply_cds
				else
					log_step "Skipping CDS for mode $mode on Flannel"
				fi
				;;
			nodeport_service)
				log_step "Applying NodePort service"
				kubectl apply -f "$ROOT_DIR/_common/services/node_port.yaml"
				;;
			*) die "Unknown mode action: $action" ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

mFlag=1
OFFLINE_MODE="false"
while [ $# -gt 0 ]; do
	case "$1" in
		-m)
			[ $# -ge 2 ] || die "Option -m requires a mode value"
			mFlag="$2"
			if ! [[ "$mFlag" =~ ^[1-7]$ ]]; then
				echo "Error: Invalid mode. Must be 1-7."
				usage
			fi
			shift 2
			;;
		-o|--offline)
			OFFLINE_MODE="true"
			shift
			;;
		-h|--help)
			usage
			;;
		*)
			echo "Error: Invalid option $1."
			usage
			;;
	esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$OFFLINE_MODE" = "true" ] && [ "$mFlag" = "6" ]; then
	die "Mode 6 (Routing Service to cloud) is not supported in offline mode. Run without --offline."
fi

preflight_checks
validate_mode_cni_compatibility "$mFlag"
cleanup_if_needed "$mFlag"

log_section "MODE"
log_step "Mode $mFlag: $(mode_label "$mFlag")"

log_section "ANTREA"
if cluster_uses_antrea; then
	if [ "$mFlag" = "2" ]; then
		log_step "Antrea detected: enabling multicast (tunnelType=vxlan)"
		set_antrea_multicast true
	else
		log_step "Antrea detected: disabling multicast (tunnelType=vxlan)"
		set_antrea_multicast false
	fi
else
	log_step "Antrea not detected (likely Flannel): skipping Antrea config patch"
fi

log_section "CONFIGMAPS"
configure_workload_configmaps "$mFlag"

log_section "WORKLOAD DEPLOY"
log_step "Mode $mFlag: $(mode_label "$mFlag")"

if mode_requires_multus "$mFlag"; then
	log_step "Mode requires Multus/MACVLAN infrastructure"
	deploy_multus_infrastructure
fi

run_mode_actions "$mFlag"

echo "$mFlag" > "$DEPLOY_MODE_STATE_FILE"

log_section "COMPLETE"
log_step "Deployment complete"
