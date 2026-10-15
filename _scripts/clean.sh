#!/bin/bash

#
# K3s Cluster Cleanup Script
# Removes all deployments, statefulsets, daemonsets (except antrea), network attachments, and services
# Also runs CNI cleanup to remove mounted CNI plugin directories
#
# Usage: $0 [--shapes-only]
#
# Prerequisites: kubectl configured, cluster access
#
set -o pipefail

SHAPES_ONLY=false
if [ "$1" = "--shapes-only" ]; then
	SHAPES_ONLY=true
fi

log_section() {
	echo ""
	echo "========== CLEANUP :: $1 =========="
}

log_step() {
	echo "[clean] $1"
}

log_section "START"
if [ "$SHAPES_ONLY" = true ]; then
	log_step "Mode: shapes-only"
else
	log_step "Mode: full"
fi
log_step "Cleaning deployments, statefulsets, daemonsets, services, and network attachments"

preflight_checks() {
	if ! command -v kubectl > /dev/null 2>&1; then
		echo "Error: kubectl is not installed or not in PATH."
		exit 1
	fi

	if ! kubectl get nodes --no-headers > /dev/null 2>&1; then
		echo "Error: Unable to reach Kubernetes cluster with kubectl."
		exit 1
	fi
}

delete_namespaced_resources() {
	local label=$1
	local kind=$2
	local resources=$3
	shift 3
	local extra_args=("$@")

	if [ -n "$resources" ]; then
		local count
		count=$(printf "%s\n" "$resources" | wc -l)
		log_section "DELETE :: $label"
		log_step "Found $count resource(s)"
		while IFS= read -r line; do
			local namespace
			local name
			namespace=$(echo "$line" | awk '{print $1}')
			name=$(echo "$line" | awk '{print $2}')
			log_step "Deleting $kind/$name in namespace $namespace"
			kubectl delete "$kind" "$name" -n "$namespace" "${extra_args[@]}"
		done <<< "$resources"
		log_step "Completed delete for $label"
	else
		log_section "DELETE :: $label"
		log_step "No resources found"
	fi
}

clean_shapes_workloads_only() {
	log_section "SHAPES-ONLY CLEANUP"
	log_step "Cleaning Shapes deployments, statefulsets, daemonsets, and user services"

	local shapes_deployments
	local shapes_statefulsets
	local shapes_daemonsets
	local user_services

	shapes_deployments=$(kubectl get deployments -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null | awk '$1 != "kube-system" && $2 ~ /^shapes-/{print $1" "$2}')
	delete_namespaced_resources "Shapes deployments" "deployment" "$shapes_deployments"

	shapes_statefulsets=$(kubectl get statefulsets -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null | awk '$1 != "kube-system" && $2 ~ /^shapes-/{print $1" "$2}')
	delete_namespaced_resources "Shapes statefulsets" "statefulset" "$shapes_statefulsets"

	shapes_daemonsets=$(kubectl get daemonsets -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null | awk '$1 != "kube-system" && $2 ~ /^shapes-/{print $1" "$2}')
	delete_namespaced_resources "Shapes daemonsets" "daemonset" "$shapes_daemonsets" --grace-period=30 --wait=true

	user_services=$(kubectl get svc -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null | \
		grep -vE '^(kube-system|kube-public|kube-node-lease)\s' | \
		grep -vE '^default\s+kubernetes$')
	delete_namespaced_resources "user-created services" "svc" "$user_services"

	log_section "SHAPES-ONLY CLEANUP COMPLETE"
}

preflight_checks

if [ "$SHAPES_ONLY" = true ]; then
	clean_shapes_workloads_only
	exit 0
fi

# Get all deployments across all namespaces (excluding kube-system)
DEPLOYMENTS=$(kubectl get deployments -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name | grep -v "^kube-system")
delete_namespaced_resources "deployments" "deployment" "$DEPLOYMENTS"

# Get all statefulsets across all namespaces (excluding kube-system)
STATEFULSETS=$(kubectl get statefulsets -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name | grep -v "^kube-system")
delete_namespaced_resources "statefulsets" "statefulset" "$STATEFULSETS"

# Get all daemonsets across all namespaces (excluding antrea if enabled)
DAEMONSETS=$(kubectl get daemonsets -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name | grep -v "antrea")
delete_namespaced_resources "daemonsets" "daemonset" "$DAEMONSETS" --grace-period=30 --wait=true

# Run CNI cleanup DaemonSet only if Multus NetworkAttachmentDefinitions are present
NAD_COUNT=$(kubectl get net-attach-def -A --no-headers 2>/dev/null | wc -l)
if [ "$NAD_COUNT" -gt 0 ]; then
	log_section "CNI CLEANUP"
	log_step "NetworkAttachmentDefinitions found: $NAD_COUNT"
	log_step "Running CNI cleanup DaemonSet"
	kubectl apply -f _helper_yaml/cni-cleanup.yaml
	kubectl rollout status daemonset cni-cleanup -n kube-system --timeout=120s
	cleanup_pod=$(kubectl get pods -n kube-system -l app=cni-cleanup -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
	if [ -n "$cleanup_pod" ]; then
		log_step "CNI cleanup initContainer logs (tail)"
		kubectl logs -n kube-system "$cleanup_pod" -c cleanup-cni --tail=20
	fi
	kubectl delete -f _helper_yaml/cni-cleanup.yaml
	log_step "CNI cleanup DaemonSet complete"
else
	log_section "CNI CLEANUP"
	log_step "No NetworkAttachmentDefinitions found - skipping"
fi

# Delete network attachment definitions
NET_ATTACH_DEFS=$(kubectl get net-attach-def -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null)
delete_namespaced_resources "network attachment definitions" "net-attach-def" "$NET_ATTACH_DEFS"

# Delete user-created services (exclude system namespaces and kubernetes service)
SERVICES=$(kubectl get svc -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name | \
	grep -vE '^(kube-system|kube-public|kube-node-lease)\s' | \
	grep -vE '^default\s+kubernetes$')
delete_namespaced_resources "user-created services" "svc" "$SERVICES"

log_section "COMPLETE"
log_step "Cleanup complete"
