#!/bin/bash

# Build and push the CNI plugins assets image used by cni-plugins-installer.
# The image embeds offline archives from _offline_assets/cni-plugins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/_offline_assets/cni-plugins"
DOCKERFILE_PATH="$ROOT_DIR/containers/cni_plugins_assets/Dockerfile"
IMAGE_TAG="v1.4.0"

usage() {
  cat <<EOF
Usage: $0 -m <mirror>

Options:
  -m, --mirror   Target mirror registry (required), e.g. 192.168.2.60:5000
  -h, --help     Show this help
EOF
}

normalize_registry() {
  local reg="$1"
  reg="${reg#http://}"
  reg="${reg#https://}"
  reg="${reg%/}"
  echo "$reg"
}

require_file() {
  local path="$1"
  [ -f "$path" ] || { echo "Error: missing required file: $path" >&2; exit 1; }
}

MIRROR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mirror)
      [ $# -lt 2 ] && { echo "Error: missing value for $1" >&2; exit 1; }
      MIRROR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[ -z "$MIRROR" ] && { usage; echo "Error: --mirror is required" >&2; exit 1; }
MIRROR="$(normalize_registry "$MIRROR")"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required" >&2; exit 1; }

require_file "$DOCKERFILE_PATH"
require_file "$ASSETS_DIR/cni-plugins-linux-amd64-v1.4.0.tgz"
require_file "$ASSETS_DIR/cni-plugins-linux-arm64-v1.4.0.tgz"
require_file "$ASSETS_DIR/cni-plugins-linux-arm-v1.4.0.tgz"

IMAGE_REF="$MIRROR/library/cni-plugins-assets:$IMAGE_TAG"

echo "Building and pushing: $IMAGE_REF"
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --output "type=registry,name=$IMAGE_REF,push=true,registry.insecure=true" \
  -f "$DOCKERFILE_PATH" \
  "$ROOT_DIR"

echo "Done: $IMAGE_REF"
