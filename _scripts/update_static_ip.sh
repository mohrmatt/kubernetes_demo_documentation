#!/bin/bash

#
# Update static IP placeholders and managed IP fields in deployment manifests and QoS files.
# Replaces repository and cluster IP placeholders or previously stamped values with the provided IP address.
# Files are marked with git skip-worktree so local IP changes are not staged for commit.
#
# Usage:
#   ./_scripts/update_static_ip.sh <ip>       # Set IP in common manifests and QoS files
#   ./_scripts/update_static_ip.sh --undo      # Re-enable git tracking on stamped files
#

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

static_repo_ip_files=(
    "$root_dir/_common/pub/base/shapes_pub.yaml"
    "$root_dir/_common/sub/base/shapes_sub.yaml"
    "$root_dir/_common/rs/base/shapes_rs.yaml"
    "$root_dir/_common/cds/shapes_cds.yaml"
)

static_cluster_ip_files=(
    "$root_dir/containers/routing_service/qos/USER_ROUTING_SERVICE.xml"
    "$root_dir/_example/external_app_qos/USER_QOS_PROFILES.xml"
)

list_managed_files() {
    printf '%s\n' "${static_repo_ip_files[@]}"
    printf '%s\n' "${static_cluster_ip_files[@]}"
}

print_box_line() {
    local width="$1"
    local text="$2"
    printf '║ %-*s ║\n' "$width" "$text"
}

print_warning_box() {
    local lines=("$@")
    local title="⚠  WARNING — READ THIS  ⚠"
    local title_len
    # wc -m counts Unicode characters, not bytes — needed for correct centering with multi-byte chars
    title_len=$(printf '%s' "$title" | wc -m)
    title_len=$(( title_len + 0 ))

    local width=$title_len
    local line
    local i
    local border=''

    for line in "${lines[@]}"; do
        [ "${#line}" -gt "$width" ] && width=${#line}
    done

    for ((i=0; i<width+2; i++)); do border+='═'; done

    # Build padding manually so the title ║ borders align with ╠═╣ below
    local pad=$(( (width - title_len) / 2 ))
    local right_pad=$(( width - title_len - pad ))
    local centered_title
    centered_title=$(printf '%*s%s%*s' "$pad" '' "$title" "$right_pad" '')

    printf '╔%s╗\n' "$border"
    printf '║ %s ║\n' "$centered_title"
    printf '╠%s╣\n' "$border"
    print_box_line "$width" ""

    for line in "${lines[@]}"; do
        print_box_line "$width" "$line"
    done

    print_box_line "$width" ""
    printf '╚%s╝\n' "$border"
}

mark_skip_worktree() {
    local file="$1"
    local rel_file="${file#$root_dir/}"

    if git -C "$root_dir" ls-files --error-unmatch "$rel_file" >/dev/null 2>&1; then
        git -C "$root_dir" update-index --skip-worktree "$rel_file"
        echo "Marked skip-worktree: $file"
    else
        echo "Skipping skip-worktree (untracked file): $file"
    fi
}

clear_skip_worktree() {
    local file="$1"
    local rel_file="${file#$root_dir/}"

    if git -C "$root_dir" ls-files --error-unmatch "$rel_file" >/dev/null 2>&1; then
        git -C "$root_dir" update-index --no-skip-worktree "$rel_file"
        echo "Cleared skip-worktree: $file"
        return 0
    fi

    return 1
}

replace_static_ip_placeholders() {
    local file="$1"
    local ip="$2"

    case "$file" in
        *.yaml)
            if grep -qE '<static repo ip>|[0-9]{1,3}(\.[0-9]{1,3}){3}:5000/' "$file"; then
                sed -i -E "s|<static repo ip>|$ip|g; s|([[:space:]]image:[[:space:]]*)[0-9]{1,3}(\.[0-9]{1,3}){3}:5000/|\\1$ip:5000/|g" "$file"
                return 0
            fi
            ;;
        */USER_ROUTING_SERVICE.xml)
            if grep -qE '<Static_Cluster_IP>|<static_cluster_ip>|<Static Cluster IP>|<static cluster ip>|<public_address>[0-9]{1,3}(\.[0-9]{1,3}){3}</public_address>' "$file"; then
                sed -i -E "s|<Static_Cluster_IP>|$ip|g; s|<static_cluster_ip>|$ip|g; s|<Static Cluster IP>|$ip|g; s|<static cluster ip>|$ip|g; s|<public_address>[0-9]{1,3}(\.[0-9]{1,3}){3}</public_address>|<public_address>$ip</public_address>|g" "$file"
                return 0
            fi
            ;;
        */USER_QOS_PROFILES.xml)
            if grep -qE '<Static_Cluster_IP>|<static_cluster_ip>|<Static Cluster IP>|<static cluster ip>|udpv4_wan://[0-9]{1,3}(\.[0-9]{1,3}){3}:30007' "$file"; then
                sed -i -E "s|<Static_Cluster_IP>|$ip|g; s|<static_cluster_ip>|$ip|g; s|<Static Cluster IP>|$ip|g; s|<static cluster ip>|$ip|g; s|udpv4_wan://[0-9]{1,3}(\.[0-9]{1,3}){3}:30007|udpv4_wan://$ip:30007|g" "$file"
                return 0
            fi
            ;;
    esac

    return 1
}

restore_static_ip_placeholders() {
    local file="$1"

    case "$file" in
        *.yaml)
            if grep -qE '[0-9]{1,3}(\.[0-9]{1,3}){3}:5000/' "$file"; then
                sed -i -E 's|([[:space:]]image:[[:space:]]*)[0-9]{1,3}(\.[0-9]{1,3}){3}:5000/|\1<static repo ip>:5000/|g' "$file"
                return 0
            fi
            ;;
        */USER_ROUTING_SERVICE.xml)
            if grep -qE '<public_address>[0-9]{1,3}(\.[0-9]{1,3}){3}</public_address>' "$file"; then
                sed -i -E 's|<public_address>[0-9]{1,3}(\.[0-9]{1,3}){3}</public_address>|<public_address><Static_Cluster_IP></public_address>|g' "$file"
                return 0
            fi
            ;;
        */USER_QOS_PROFILES.xml)
            if grep -qE 'udpv4_wan://[0-9]{1,3}(\.[0-9]{1,3}){3}:30007' "$file"; then
                sed -i -E 's|udpv4_wan://[0-9]{1,3}(\.[0-9]{1,3}){3}:30007|udpv4_wan://<Static_Cluster_IP>:30007|g' "$file"
                return 0
            fi
            ;;
    esac

    return 1
}

if ! git -C "$root_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: $root_dir is not a git repository." >&2
    exit 1
fi

# ── Undo mode ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--undo" ]]; then
    undo_count=0
    restored_count=0

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if restore_static_ip_placeholders "$file"; then
            echo "Restored placeholders: $file"
            restored_count=$((restored_count + 1))
        fi
        if clear_skip_worktree "$file"; then
            undo_count=$((undo_count + 1))
        fi
    done < <(list_managed_files)

    echo ""
    echo "Restored placeholders in $restored_count file(s)."
    echo "Restored git tracking on $undo_count file(s)."

    echo ""
    print_warning_box \
        "Git is now TRACKING the managed files again." \
        "" \
        "The repository placeholders have been restored where stamped" \
        "IP values were found, so these files are ready for normal edits" \
        "and review before commit." \
        "" \
        "To stamp your local IP again later, run:" \
        "  ./_scripts/update_static_ip.sh <ip>"
    exit 0
fi

# ── Update mode ───────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <ip>" >&2
    echo "       $0 --undo" >&2
    echo "Example: $0 192.168.1.100" >&2
    exit 1
fi

static_ip="$1"

# Validate IP format (basic dotted-quad check)
if ! [[ "$static_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format: $static_ip" >&2
    exit 1
fi

updated_count=0

while IFS= read -r file; do
    [ -n "$file" ] || continue

    if ! replace_static_ip_placeholders "$file" "$static_ip"; then
        continue
    fi

    mark_skip_worktree "$file"
    echo "Updated: $file"
    updated_count=$((updated_count + 1))
done < <(list_managed_files)

if [[ $updated_count -eq 0 ]]; then
    echo "No managed files with supported static IP placeholders found."
    exit 1
fi

echo ""
echo "Successfully updated $updated_count file(s) with static IP: $static_ip"

echo ""
print_warning_box \
    "The files above have been marked with 'git skip-worktree' so" \
    "your local IP changes are hidden from git staging." \
    "" \
    "DO NOT commit these files - they contain your local IP address" \
    "($static_ip) and will break deployments for everyone else." \
    "" \
    "To re-enable git tracking on these files (e.g. to revert or" \
    "update the placeholder), run:" \
    "  ./_scripts/update_static_ip.sh --undo"
