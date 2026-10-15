#!/usr/bin/env bash
set -euo pipefail

run_mode="publisher"
app_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    subscriber)
      run_mode="subscriber"
      shift
      ;;
    --subscriber)
      run_mode="subscriber"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [subscriber] [application-options]

Mode selection:
  subscriber            Run ShapeType_subscriber (default runs publisher)

Application options (forwarded to Shapes binary):
  -d, --domain <int>
  -s, --sample-count <int>
  -v, --verbosity <0-3>
  -c, --color <str>
  --cds
  --macvlan
  --qos-profile <str>

Examples:
  $0
  $0 subscriber --cds --qos-profile ShapeType_Library::ShapeType_Profile
  $0 -c BLUE --macvlan
EOF
      exit 0
      ;;
    *)
      app_args+=("$1")
      shift
      ;;
  esac
done

arch="$(uname -m)"
case "$arch" in
  aarch64|arm64)
    if [[ "$run_mode" == "subscriber" ]]; then
      bin_path="/app/objs/armv8Linux4gcc7.3.0/ShapeType_subscriber"
    else
      bin_path="/app/objs/armv8Linux4gcc7.3.0/ShapeType_publisher"
    fi
    ;;
  x86_64|amd64)
    if [[ "$run_mode" == "subscriber" ]]; then
      bin_path="/app/objs/x64Linux4gcc7.3.0/ShapeType_subscriber"
    else
      bin_path="/app/objs/x64Linux4gcc7.3.0/ShapeType_publisher"
    fi
    ;;
  *)
    echo "Unsupported arch: $arch" >&2
    exit 1
    ;;
esac

  exec "$bin_path" "${app_args[@]}"
