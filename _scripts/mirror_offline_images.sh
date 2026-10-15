#!/bin/bash

# Pull, retag, and push all images required for offline deployments.
# Both linux/amd64 and linux/arm64 are mirrored as a multi-arch manifest list.

export DOCKER_CLI_EXPERIMENTAL=enabled

set -euo pipefail

die() {
    echo "Error: $*" >&2
    exit 1
}

log() {
    echo "$*"
}

usage() {
    cat <<EOF
Usage: $0 -m <mirror> [-k]

Options:
  -m, --mirror           Target mirror registry (required), e.g. 192.168.2.60:5000
    -k, --keep-local       Keep local image tags after push
  -h, --help             Show this help

Examples:
  $0 -m 192.168.2.60:5000
    $0 -m 192.168.2.60:5000 --keep-local
EOF
}

normalize_registry() {
    local reg="$1"
    reg="${reg#http://}"
    reg="${reg#https://}"
    reg="${reg%/}"
    echo "$reg"
}

image_exists_in_mirror() {
    local dst="$1"
    local ref_no_registry
    local repo
    local tag

    ref_no_registry="${dst#${MIRROR}/}"
    repo="${ref_no_registry%:*}"
    tag="${ref_no_registry##*:}"

    # Check by manifest first (supports both single-arch and multi-arch tags).
    if curl -fsS -o /dev/null 2>/dev/null \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
        "http://${MIRROR}/v2/${repo}/manifests/${tag}"; then
        return 0
    fi

    # Fallback for registries that do not return manifests consistently for HEAD/GET.
    curl -fsS "http://${MIRROR}/v2/${repo}/tags/list" 2>/dev/null | grep -F "\"${tag}\"" >/dev/null
}

image_has_required_arches_in_mirror() {
    local dst="$1"
    shift
    local required_arches=("$@")
    local ref_no_registry
    local repo
    local tag
    local manifest_json

    ref_no_registry="${dst#${MIRROR}/}"
    repo="${ref_no_registry%:*}"
    tag="${ref_no_registry##*:}"

    manifest_json="$(curl -fsS 2>/dev/null \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
        "http://${MIRROR}/v2/${repo}/manifests/${tag}")" || return 1

    # Only manifest lists/indexes can contain multiple architectures.
    echo "$manifest_json" | grep -q '"manifests"' || return 1

    local arch
    for arch in "${required_arches[@]}"; do
        echo "$manifest_json" | grep -Eq "\"architecture\"[[:space:]]*:[[:space:]]*\"${arch}\"" || return 1
    done

    return 0
}

mirror_image() {
    local src="$1"
    local dst="$2"
    local archs=("amd64" "arm64")
    local arch_tags=()

    if image_exists_in_mirror "$dst"; then
        if image_has_required_arches_in_mirror "$dst" "${archs[@]}"; then
            log "Skipping (already in mirror with required arches): $dst"
            return 0
        fi

        log "Image exists but is missing required arches; refreshing: $dst"
    fi

    # Pull, tag, and push each architecture individually.
    for arch in "${archs[@]}"; do
        local arch_dst="${dst}-${arch}"
        arch_tags+=("$arch_dst")

        log "Pulling: $src (linux/$arch)"
        docker pull --platform "linux/${arch}" "$src"

        log "Tagging: $src -> $arch_dst"
        docker tag "$src" "$arch_dst"

        log "Pushing: $arch_dst"
        docker push "$arch_dst"

        if [ "$KEEP_LOCAL" = "false" ]; then
            docker image rm "$arch_dst" >/dev/null 2>&1 || true
            docker image rm "$src" >/dev/null 2>&1 || true
        fi
    done

    # Create and push a multi-arch manifest list for the main tag.
    log "Creating multi-arch manifest: $dst -> [${arch_tags[*]}]"
    # Local mirror is HTTP/insecure, so manifest operations must use --insecure.
    if ! docker manifest create --insecure --amend "$dst" "${arch_tags[@]}"; then
        log "Manifest create failed for $dst"
        log "Checking per-arch tags in mirror..."
        for arch_tag in "${arch_tags[@]}"; do
            if image_exists_in_mirror "$arch_tag"; then
                log "  found: $arch_tag"
            else
                log "  missing: $arch_tag"
            fi
        done
        die "Unable to create multi-arch manifest for $dst"
    fi

    docker manifest push --insecure "$dst"

    if [ "$KEEP_LOCAL" = "false" ]; then
        docker manifest rm "$dst" >/dev/null 2>&1 || true
    fi
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not found in PATH"
}

require_docker_daemon_config() {
    local daemon_json="/etc/docker/daemon.json"
    [ -f "$daemon_json" ] || die "$daemon_json not found. Configure Docker to trust the local mirror before running this script, or pushes to the local mirror may fail."
}

MIRROR=""
KEEP_LOCAL="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mirror)
            [ $# -lt 2 ] && die "Missing value for $1"
            MIRROR="$2"
            shift 2
            ;;
        -k|--keep-local)
            KEEP_LOCAL="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[ -z "$MIRROR" ] && { usage; die "--mirror is required"; }

MIRROR="$(normalize_registry "$MIRROR")"

require_cmd docker
require_cmd curl
require_docker_daemon_config

log "Target mirror: $MIRROR"

# Public/base images used by offline manifests and helper DaemonSets.
mirror_image "ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot" "$MIRROR/k8snetworkplumbingwg/multus-cni:snapshot"
mirror_image "ghcr.io/k8snetworkplumbingwg/whereabouts:latest" "$MIRROR/k8snetworkplumbingwg/whereabouts:latest"
mirror_image "docker.io/bitnami/kubectl:latest" "$MIRROR/bitnami/kubectl:latest"
mirror_image "docker.io/library/busybox:1.36" "$MIRROR/library/busybox:1.36"
mirror_image "docker.io/library/alpine:latest" "$MIRROR/library/alpine:latest"
mirror_image "registry.k8s.io/pause:3.6" "$MIRROR/pause:3.6"
mirror_image "docker.io/rancher/mirrored-pause:3.6" "$MIRROR/rancher/mirrored-pause:3.6"
mirror_image "docker.io/antrea/antrea-agent-ubuntu:latest" "$MIRROR/antrea/antrea-agent-ubuntu:latest"
mirror_image "docker.io/antrea/antrea-controller-ubuntu:latest" "$MIRROR/antrea/antrea-controller-ubuntu:latest"

log "Offline image mirroring complete."
