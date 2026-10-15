#!/bin/bash

#
# Kubernetes Pod Restart Manager
# Interactively selects and restarts one or more pods in the cluster
#
# Usage: $0
#
# Prerequisites: kubectl configured
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

preflight_checks


usage() {
	echo "Usage: $0"
	exit 1
}

if [ $# -ne 0 ]; then
	usage
fi

# Fetch pods
echo "Fetching pods..."
mapfile -t PODS < <(fetch_all_pods)

# Display available pods
list_pods "${PODS[@]}"

# Prompt for selection
selection=$(prompt_selection "Enter pod numbers to restart (space-separated, e.g., '1 3 5')")
parse_selection "$selection" "${#PODS[@]}"

# Display selected pods
echo ""
echo "You are about to restart the following pod(s):"
for sel in "${SELECTED[@]}"; do
	IFS=':' read -r namespace name node <<< "${PODS[$((sel-1))]}"
	echo "  - $name (namespace: $namespace, node: $node)"
done

# Confirm action
confirm_action "Are you sure you want to restart these pods?"

# Restart pods
echo ""
echo "Restarting pods..."
for sel in "${SELECTED[@]}"; do
	IFS=':' read -r namespace name node <<< "${PODS[$((sel-1))]}"
	echo "Restarting pod: $name (namespace: $namespace, node: $node)"
	kubectl delete pod "$name" -n "$namespace" || die "Failed to restart pod $name"
done

echo ""
echo "Restart complete. Pods will be recreated by their controllers."
