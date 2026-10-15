#!/bin/bash

#
# Kubernetes Resource Deletion Manager
# Interactively selects and deletes deployments, daemonsets, statefulsets, services, and nodes
#
# Usage: $0
#
# Prerequisites: kubectl configured
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

preflight_checks

join_selected_names() {
	local names=()
	for sel in "${SELECTED[@]}"; do
		names+=("$(get_item_name "${ITEMS[$((sel-1))]}")")
	done
	local IFS=", "
	echo "${names[*]}"
}

get_item_type() {
	local item="$1"
	echo "${item%%:*}"
}

get_item_rest() {
	local item="$1"
	echo "${item#*:}"
}

get_item_name() {
	local item="$1"
	local type
	local rest
	type=$(get_item_type "$item")
	rest=$(get_item_rest "$item")
	case "$type" in
		deployment|daemonset|service|statefulset)
			IFS=':' read -r _namespace name <<< "$rest"
			echo "$name"
			;;
		node)
			awk '{print $1}' <<< "$rest"
			;;
		*)
			echo "$rest"
			;;
	esac
}

get_item_namespace() {
	local item="$1"
	local type
	local rest
	type=$(get_item_type "$item")
	rest=$(get_item_rest "$item")
	case "$type" in
		deployment|daemonset|service|statefulset)
			IFS=':' read -r namespace _name <<< "$rest"
			echo "$namespace"
			;;
		*)
			echo ""
			;;
	esac
}

print_section() {
	local label="$1"
	local type_filter="$2"
	local has_items=false
	for item in "${ITEMS[@]}"; do
		[ "$(get_item_type "$item")" = "$type_filter" ] && has_items=true
	done
	if [ "$has_items" = true ]; then
		echo ""
		echo "=== $label ==="
		for i in "${!ITEMS[@]}"; do
			if [ "$(get_item_type "${ITEMS[$i]}")" = "$type_filter" ]; then
				printf "%3d) %s\n" $((i+1)) "$(get_item_name "${ITEMS[$i]}")"
			fi
		done
	fi
}

delete_item() {
	local item="$1"
	local type
	local name
	local namespace
	type=$(get_item_type "$item")
	name=$(get_item_name "$item")
	namespace=$(get_item_namespace "$item")
	case "$type" in
		deployment|daemonset|statefulset)
			echo "Deleting $type: $name (namespace: $namespace)"
			kubectl delete "$type" "$name" -n "$namespace"
			;;
		service)
			echo "Deleting service: $name (namespace: $namespace)"
			kubectl delete svc "$name" -n "$namespace"
			;;
		node)
			echo "Deleting node: $name"
			kubectl delete node "$name"
			;;
	esac
}

if [ $# -ne 0 ]; then
	die "This script does not take command line options."
fi

delete_items() {
	echo "Fetching deletable items..."
	echo ""

	ITEMS=()
	while IFS= read -r line; do
		ITEMS+=("deployment:$line")
	done < <(kubectl get deployments -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers | awk '{print $1":"$2}')

	while IFS= read -r line; do
		ITEMS+=("daemonset:$line")
	done < <(kubectl get daemonsets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers | awk '{print $1":"$2}')

	while IFS= read -r line; do
		ITEMS+=("statefulset:$line")
	done < <(kubectl get statefulsets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers | awk '{print $1":"$2}')

	while IFS= read -r line; do
		ITEMS+=("service:$line")
	done < <(kubectl get svc -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers | \
		grep -vE '^(kube-system|kube-public|kube-node-lease)\s' | \
		grep -vE '^default\s+kubernetes$' | \
		awk '{print $1":"$2}')

	while IFS= read -r line; do
		ITEMS+=("node:$line")
	done < <(kubectl get nodes --no-headers -o wide | awk '$3 !~ /control-plane|master/')

	[ ${#ITEMS[@]} -eq 0 ] && die "No deletable items found in the cluster."

	echo "Available items:"
	print_section "DEPLOYMENTS" "deployment"
	print_section "DAEMONSETS" "daemonset"
	print_section "STATEFULSETS" "statefulset"
	print_section "SERVICES" "service"
	print_section "NODES" "node"

	selection=$(prompt_selection "Enter item numbers to delete (space-separated, e.g., '1 3 5'):")
	parse_selection "$selection" "${#ITEMS[@]}"

	selected_list=$(join_selected_names)
	confirm_action "Are you sure you want to delete: $selected_list?"

	echo ""
	echo "Deleting items..."
	for sel in "${SELECTED[@]}"; do
		delete_item "${ITEMS[$((sel-1))]}"
	done

	echo ""
	echo "Deletion complete."
}

delete_items
