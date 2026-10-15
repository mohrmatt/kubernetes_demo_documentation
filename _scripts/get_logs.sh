#!/bin/bash

#
# Kubernetes Pod Log Viewer
# Displays the last 100 lines of logs from a selected pod
#
# Usage: $0
#
# Prerequisites: kubectl configured
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

preflight_checks

select_container() {
	local namespace="$1"
	local pod_name="$2"
	local containers=()
	local item

	while IFS= read -r item; do
		[ -n "$item" ] && containers+=("[container] $item")
	done < <(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')

	while IFS= read -r item; do
		[ -n "$item" ] && containers+=("[init] $item")
	done < <(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}')

	if [ ${#containers[@]} -eq 0 ]; then
		die "No containers found for pod $pod_name"
	fi

	if [ ${#containers[@]} -eq 1 ]; then
		echo "${containers[0]}"
		return
	fi

	echo "Available containers:" >&2
	echo "" >&2
	for i in "${!containers[@]}"; do
		printf "%3d) %s\n" $((i+1)) "${containers[$i]}" >&2
	done
	echo "" >&2

	local selection
	selection=$(prompt_selection "Select a container to view logs (1-${#containers[@]}):")

	if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#containers[@]} ]; then
		die "Invalid selection. Please enter a number between 1 and ${#containers[@]}."
	fi

	echo "${containers[$((selection-1))]}"
}

# Fetch pods
echo "Fetching pods..."
mapfile -t PODS < <(fetch_all_pods)

# Get the selected pod
SELECTED_POD=$(select_pod "Select a pod to view logs" "${PODS[@]}")
IFS=':' read -r namespace name <<< "$SELECTED_POD"

SELECTED_CONTAINER=$(select_container "$namespace" "$name")
CONTAINER_TYPE=$(echo "$SELECTED_CONTAINER" | awk '{print $1}')
CONTAINER_NAME=$(echo "$SELECTED_CONTAINER" | sed 's/^\[[^]]*\] //')

echo ""
echo "Displaying logs for pod: $name (namespace: $namespace)"
echo "Container: $CONTAINER_NAME $CONTAINER_TYPE"
echo "========================================================"
echo ""

kubectl logs "$name" -n "$namespace" -c "$CONTAINER_NAME" --tail=100 || die "Failed to fetch logs"
