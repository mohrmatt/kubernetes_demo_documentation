#!/usr/bin/env bash
set -euo pipefail

cfg_name="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--cfgName)
      cfg_name="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [-c|--cfgName <name>]" >&2
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [-c|--cfgName <name>]" >&2
      exit 1
      ;;
  esac
done

arch="$(uname -m)"
case "$arch" in
  aarch64|arm64)
    bin_path="/app/bin/armv8Linux4gcc7.3.0/rticlouddiscoveryserviceapp"
    lib_path="/app/libs/armv8Linux4gcc7.3.0"
    ;;
  x86_64|amd64)
    bin_path="/app/bin/x64Linux4gcc7.3.0/rticlouddiscoveryserviceapp"
    lib_path="/app/libs/x64Linux4gcc7.3.0"
    ;;
  *)
    echo "Unsupported arch: $arch" >&2
    exit 1
    ;;
esac

export LD_LIBRARY_PATH="$lib_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$bin_path" -cfgName "$cfg_name" -cfgFile /app/qos/RTI_CLOUD_DISCOVERY_SERVICE.xml