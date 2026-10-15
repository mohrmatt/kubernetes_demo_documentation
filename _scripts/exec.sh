#!/bin/bash

#
# Kubernetes Pod Shell/Packet Capture
# Opens an interactive shell in a pod or captures network packets using tcpdump
#
# Usage: $0 [-t]
# Options:
#   -t: run tcpdump packet capture in the pod instead of opening shell
#
# Prerequisites: kubectl configured, pod must have tcpdump installed (for -t option)
#

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

preflight_checks

# Parse command line options
TCPDUMP_MODE=false

while getopts ":t" OPT; do
	case "$OPT" in
		t) TCPDUMP_MODE=true ;;
		?) die "Invalid option: -$OPTARG. Usage: $0 [-t]" ;;
	esac
done

# Fetch pods
echo "Fetching pods..."
mapfile -t PODS < <(fetch_all_pods)

# In tcpdump mode, only allow Shapes pods (expected to include tcpdump).
if [ "$TCPDUMP_MODE" = true ]; then
	FILTERED_PODS=()
	for pod in "${PODS[@]}"; do
		IFS=':' read -r namespace name node <<< "$pod"
		if [[ "$name" =~ ^shapes- ]]; then
			FILTERED_PODS+=("$pod")
		fi
	done

	if [ ${#FILTERED_PODS[@]} -eq 0 ]; then
		die "No Shapes pods found for tcpdump mode."
	fi

	PODS=("${FILTERED_PODS[@]}")
fi

# Get the selected pod
SELECTED_POD=$(select_pod "Select a pod to exec into" "${PODS[@]}")
IFS=':' read -r namespace name <<< "$SELECTED_POD"

if [ "$TCPDUMP_MODE" = true ]; then
	echo ""
	echo "Starting tcpdump capture in pod: $name (namespace: $namespace)"
	echo "=============================================================="
	echo "Press Ctrl+C to stop the capture..."
	echo ""
	
	TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
	CAPTURE_FILE="${TIMESTAMP}.pcap"
	
	# Set trap to handle Ctrl+C gracefully
	trap 'echo ""; echo "Capture interrupted. Extracting data..."; INTERRUPTED=true' INT
	
	# Start tcpdump and save to temp file in pod
	kubectl exec "$name" -n "$namespace" -- tcpdump -i any -w /tmp/capture.pcap
	TCPDUMP_EXIT_CODE=$?
	
	# Remove trap
	trap - INT
	
	# Check if tcpdump had a real error (not just interrupted by user)
	if [ $TCPDUMP_EXIT_CODE -ne 0 ] && [ "$INTERRUPTED" != "true" ]; then
		die "tcpdump failed. Pod may not have tcpdump installed."
	fi
	
	# Copy the capture file to current directory
	echo ""
	echo "Extracting capture to: $CAPTURE_FILE"
	kubectl cp "$namespace/$name:/tmp/capture.pcap" "./$CAPTURE_FILE" || die "Failed to copy capture file"
	
	# Clean up the temp file in the pod
	kubectl exec "$name" -n "$namespace" -- rm -f /tmp/capture.pcap || true
	
	echo "Capture saved to: $CAPTURE_FILE"
else
	echo ""
	echo "Opening shell in pod: $name (namespace: $namespace)"
	echo "====================================================="
	echo ""
	
	kubectl exec -it "$name" -n "$namespace" -- /bin/bash || die "Failed to open shell in pod"
fi
