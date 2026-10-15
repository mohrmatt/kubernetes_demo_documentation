#!/bin/bash

#
# Common library for K3s management scripts
# Provides reusable functions for error handling, kubectl operations, and user interaction
#

set -o pipefail

# Error handling function
die() {
	echo "Error: $*" >&2
	exit 1
}

# Preflight checks
preflight_checks() {
	if ! command -v kubectl > /dev/null 2>&1; then
		die "kubectl is not installed or not in PATH."
	fi

	if ! kubectl get nodes --no-headers > /dev/null 2>&1; then
		die "Unable to reach Kubernetes cluster. Ensure kubeconfig is configured and cluster is accessible."
	fi
}

# Prompt for selection
prompt_selection() {
	local prompt="$1"
	local selection
	printf "\n%s\n" "$prompt" >&2
	printf "Selection: " >&2
	IFS= read -r selection
	if [ -z "$selection" ]; then
		echo "No selection made. Exiting."
		exit 0
	fi
	echo "$selection"
}

# Validate numeric selection
parse_selection() {
	local selection="$1"
	local max="$2"
	IFS=' ' read -ra SELECTIONS <<< "$selection"
	SELECTED=()
	for sel in "${SELECTIONS[@]}"; do
		if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$max" ]; then
			die "Invalid selection: $sel (must be between 1 and $max)"
		fi
		SELECTED+=("$sel")
	done
}

# Prompt for confirmation
confirm_action() {
	local prompt="$1"
	local confirm
	printf "\n%s (y/n): " "$prompt" >&2
	IFS= read -r confirm
	if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
		echo "Cancelled."
		exit 0
	fi
}

# Fetch all pods in the cluster with node information
fetch_all_pods() {
	local pods=()
	while IFS= read -r line; do
		pods+=("$line")
	done < <(kubectl get pods -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName --no-headers | awk '{print $1":"$2":"$3}')

	if [ ${#pods[@]} -eq 0 ]; then
		die "No pods found in the cluster."
	fi

	printf '%s\n' "${pods[@]}"
}

list_pods() {
	local pods=("$@")
	if [ ${#pods[@]} -eq 0 ]; then
		die "No pods available for listing."
	fi

	local BOLD='\033[1m'
	local RESET='\033[0m'
	local GRAY_BG='\033[48;5;240m'
	local WHITE_TEXT='\033[97m'
	local DIM='\033[2m'

	echo "" >&2
	printf "${BOLD}%-3s  %-20s  %-50s  %-20s${RESET}\n" "#" "NAMESPACE" "POD" "NODE" >&2
	printf "${DIM}%-3s  %-20s  %-50s  %-20s${RESET}\n" "---" "--------------------" "--------------------------------------------------" "--------------------" >&2

	for i in "${!pods[@]}"; do
		IFS=':' read -r namespace name node <<< "${pods[$i]}"
		# Alternate row background colors for easier scanning
		if (( (i+1) % 2 == 0 )); then
			printf "${GRAY_BG}${WHITE_TEXT}%-3d  %-20s  %-50s  %-20s${RESET}\n" $((i+1)) "$namespace" "$name" "$node" >&2
		else
			printf "%-3d  %-20s  %-50s  %-20s\n" $((i+1)) "$namespace" "$name" "$node" >&2
		fi
	done
	echo "" >&2
}

# Display pods in a numbered list and prompt for selection
# Returns: namespace:name (without node)
select_pod() {
	local prompt="${1:-Select a pod}"
	local pods=("${@:2}")

	if [ ${#pods[@]} -eq 0 ]; then
		die "No pods available for selection."
	fi

	list_pods "${pods[@]}"
	local selection
	selection=$(prompt_selection "$prompt (1-${#pods[@]}):")

	if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#pods[@]} ]; then
		die "Invalid selection. Please enter a number between 1 and ${#pods[@]}."
	fi

	# Return only namespace:name (strip node information)
	local selected_pod="${pods[$((selection-1))]}"
	IFS=':' read -r namespace name node <<< "$selected_pod"
	echo "$namespace:$name"
}

# Export for use in sourced scripts
export -f die
export -f preflight_checks
export -f prompt_selection
export -f parse_selection
export -f confirm_action
export -f fetch_all_pods
export -f list_pods
export -f select_pod
