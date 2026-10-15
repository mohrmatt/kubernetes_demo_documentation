#!/bin/bash

# Refresh local offline assets used by deploy_pods.sh fallback/offline mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OFFLINE_DIR="$ROOT_DIR/_offline_assets"

MULTUS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml"
WHEREABOUTS_DAEMONSET_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/daemonset-install.yaml"
WHEREABOUTS_IPPOOLS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_ippools.yaml"
WHEREABOUTS_OVERLAPPING_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml"

mkdir -p "$OFFLINE_DIR"

echo "Refreshing offline manifests in $OFFLINE_DIR"

curl -fsSL "$MULTUS_URL" -o "$OFFLINE_DIR/multus-daemonset.yml"
curl -fsSL "$WHEREABOUTS_DAEMONSET_URL" -o "$OFFLINE_DIR/whereabouts-daemonset-install.yaml"
curl -fsSL "$WHEREABOUTS_IPPOOLS_URL" -o "$OFFLINE_DIR/whereabouts-ippools-crd.yaml"
curl -fsSL "$WHEREABOUTS_OVERLAPPING_URL" -o "$OFFLINE_DIR/whereabouts-overlappingrangeipreservations-crd.yaml"

echo "Refresh complete."
wc -l "$OFFLINE_DIR"/*.y*ml
