#!/bin/bash

#
# Kubernetes Pod Descriptor
# Displays detailed information about a pod or its network interfaces
#
# Usage: $0 [-i]
# Options:
#   -i: display network interfaces only (instead of full pod description)
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

preflight_checks

# Define a function to display usage instructions
usage() {
    echo "Usage: $0 [-i]"
    echo "Options:"
    echo "  -i: display network interfaces only"
    exit 1
}

INTERFACES_ONLY=0
while getopts ":i" OPT; do
    case "${OPT}" in
        i) INTERFACES_ONLY=1 ;;
        ?) # An invalid option was encountered
            echo "Error: Invalid option -${OPTARG}."
            usage
            ;;
    esac
done

# Fetch pods
echo "Fetching pods..."
mapfile -t PODS < <(fetch_all_pods)

# Get the selected pod
SELECTED_POD=$(select_pod "Select a pod to describe" "${PODS[@]}")
IFS=':' read -r namespace name <<< "$SELECTED_POD"

echo ""
if [ "$INTERFACES_ONLY" = "1" ]; then
	echo "Displaying network interfaces for pod: $name (namespace: $namespace)"
	echo "========================================================================"
	echo ""
    kubectl exec "$name" -n "$namespace" -- ip -brief addr show || die "Failed to fetch network interfaces"
else
	echo "Describing pod: $name (namespace: $namespace)"
	echo "================================================"
	echo ""
    kubectl describe pod "$name" -n "$namespace" || die "Failed to describe pod"
fi
