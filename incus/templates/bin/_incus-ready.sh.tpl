#!/bin/sh
set -eu

STATE={{ .Values.incus.state_path | quote }}
SOCKET={{ .Values.incus.socket | quote }}
RUNTIME={{ .Values.incus.runtime_path | quote }}
LXCFS={{ .Values.incus.lxcfs_path | quote }}

test -S "$SOCKET"
test -r "$LXCFS/proc/meminfo"
timeout 5 head -n 1 "$LXCFS/proc/meminfo" >/dev/null
INCUS_DIR="$STATE" incus admin waitready --timeout=5 >/dev/null

network_inventory=$(
  INCUS_DIR="$STATE" incus network list --all-projects \
    --columns emn --format csv
)
managed_networks=$(printf '%s\n' "$network_inventory" |
  awk -F, '$2 == "YES" {print $1 "/" $3}')
if [ -n "$managed_networks" ]; then
  echo "Incus-managed networks are unsupported on Neutron nodes: $(printf '%s' "$managed_networks" | tr '\n' ' ')" >&2
  exit 1
fi

instances=$(INCUS_DIR="$STATE" incus list --all-projects --columns ens --format csv)
printf '%s\n' "$instances" |
  while IFS=, read -r project name status; do
    [ -n "$name" ] || continue
    [ "$status" = "RUNNING" ] || continue

    runtime_name=$name
    if [ "$project" != "default" ]; then
      runtime_name="${project}_${name}"
    fi

    test -r "$RUNTIME/$runtime_name/lxc.conf" || {
      echo "Missing runtime config for $project/$name: $RUNTIME/$runtime_name/lxc.conf" >&2
      exit 1
    }
  done
