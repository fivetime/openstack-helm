#!/bin/bash

# Copyright 2023 VEXXHOST, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# OVN Controller Library Functions

# Get a specific IPv4 address from interface
function get_ip_address_from_interface {
  local interface=$1
  local ip=$(ip -4 -o addr s "${interface}" | awk '{ print $4; exit }' | awk -F '/' 'NR==1 {print $1}')
  if [ -z "${ip}" ] ; then
    exit 1
  fi
  echo ${ip}
}

# Get prefix from an IPv4 address
function get_ip_prefix_from_interface {
  local interface=$1
  local prefix=$(ip -4 -o addr s "${interface}" | awk '{ print $4; exit }' | awk -F '/' 'NR==1 {print $2}')
  if [ -z "${prefix}" ] ; then
    exit 1
  fi
  echo ${prefix}
}

# Migrate IP addresses, routes and gateway from a network interface to a bridge
# Both IPv4 and IPv6 addresses, routes and gateway are migrated properly
function migrate_ip_from_nic {
  src_nic=$1
  bridge_name=$2

  # Enabling explicit error handling
  set +e

  # Ensure the bridge interface is up
  ip link set ${bridge_name} up

  # Check if bridge already has global IP addresses (excluding link-local IPv6)
  bridge_has_addr=false
  bridge_ipv4=$(ip -4 addr show dev ${bridge_name} 2>/dev/null | grep inet)
  bridge_ipv6=$(ip -6 addr show dev ${bridge_name} 2>/dev/null | grep inet6 | grep -v "scope link")

  if [[ -n "$bridge_ipv4" ]] || [[ -n "$bridge_ipv6" ]]; then
    bridge_has_addr=true
    echo "Bridge '${bridge_name}' already has global IP configuration. Keeping as is..."
    set -e
    return 0
  fi

  # Store IPv4 addresses from source interface
  ipv4_addresses=()
  ipv4_data=$(ip -4 addr show dev ${src_nic} 2>/dev/null | grep inet)

  while read -r line; do
    if [[ -n "$line" ]]; then
      ip_prefix=$(echo "$line" | awk '{print $2}')
      broadcast=""
      if [[ "$line" =~ brd[[:space:]]([0-9.]+) ]]; then
        broadcast="brd ${BASH_REMATCH[1]}"
      fi
      scope=""
      if [[ "$line" =~ scope[[:space:]]([a-z]+) ]]; then
        scope="scope ${BASH_REMATCH[1]}"
      fi
      clean_config="${ip_prefix} ${broadcast} ${scope}"
      ipv4_addresses+=("$clean_config")
    fi
  done < <(echo "$ipv4_data")

  # Store global IPv6 addresses from source interface (excluding link-local)
  ipv6_addresses=()
  ipv6_data=$(ip -6 addr show dev ${src_nic} 2>/dev/null | grep inet6 | grep -v "scope link")

  while read -r line; do
    if [[ -n "$line" ]]; then
      ip_prefix=$(echo "$line" | awk '{print $2}')
      scope=""
      if [[ "$line" =~ scope[[:space:]]([a-z]+) ]]; then
        scope="scope ${BASH_REMATCH[1]}"
      fi
      clean_config="${ip_prefix} ${scope}"
      ipv6_addresses+=("$clean_config")
    fi
  done < <(echo "$ipv6_data")

  # Store IPv4 routes from source interface (excluding default routes)
  ipv4_routes=()
  ipv4_route_data=$(ip -4 route show dev ${src_nic} 2>/dev/null | grep -v "^default" | grep -v "proto kernel")

  while read -r line; do
    if [[ -n "$line" ]]; then
      clean_route=$(echo "$line" | sed "s/dev ${src_nic}//g" | tr -s ' ' | sed 's/^ //;s/ $//')
      if [[ -n "$clean_route" ]]; then
        ipv4_routes+=("$clean_route")
      fi
    fi
  done < <(echo "$ipv4_route_data")

  # Store IPv6 routes from source interface (excluding default routes and link-local)
  ipv6_routes=()
  ipv6_route_data=$(ip -6 route show dev ${src_nic} 2>/dev/null | grep -v "^default" | grep -v "proto kernel" | grep -v "^fe80::")

  while read -r line; do
    if [[ -n "$line" ]]; then
      clean_route=$(echo "$line" | sed "s/dev ${src_nic}//g" | tr -s ' ' | sed 's/^ //;s/ $//')
      if [[ -n "$clean_route" ]]; then
        ipv6_routes+=("$clean_route")
      fi
    fi
  done < <(echo "$ipv6_route_data")

  # Store default gateways
  ipv4_default_gw=""
  ipv6_default_gw=""

  ipv4_default=$(ip -4 route show default dev ${src_nic} 2>/dev/null | head -n1)
  if [[ -n "$ipv4_default" ]]; then
    ipv4_default_gw=$(echo "$ipv4_default" | awk '{print $3}')
    echo "Found IPv4 default gateway: ${ipv4_default_gw}"
  fi

  ipv6_default=$(ip -6 route show default dev ${src_nic} 2>/dev/null | head -n1)
  if [[ -n "$ipv6_default" ]]; then
    ipv6_default_gw=$(echo "$ipv6_default" | awk '{print $3}')
    echo "Found IPv6 default gateway: ${ipv6_default_gw}"
  fi

  # Check if we have any IPs to migrate
  if [[ ${#ipv4_addresses[@]} -eq 0 ]] && [[ ${#ipv6_addresses[@]} -eq 0 ]]; then
    echo "Interface ${src_nic} has no global IP addresses to migrate. Leaving as is."
    set -e
    return 0
  fi

  echo "Migrating ${#ipv4_addresses[@]} IPv4 and ${#ipv6_addresses[@]} IPv6 addresses from ${src_nic} to ${bridge_name}..."
  echo "Also migrating ${#ipv4_routes[@]} IPv4 routes and ${#ipv6_routes[@]} IPv6 routes..."

  migration_failed=false

  # Add IPv4 addresses to bridge
  for addr_config in "${ipv4_addresses[@]}"; do
    addr_config=$(echo "$addr_config" | tr -s ' ' | sed 's/^ //;s/ $//')
    echo "Adding IPv4 config: $addr_config to ${bridge_name}"
    if ! ip addr add $addr_config dev ${bridge_name}; then
      echo "Error: Failed to add IPv4 configuration to ${bridge_name}"
      migration_failed=true
      break
    fi
  done

  # Add IPv6 addresses to bridge
  if [[ "$migration_failed" = false ]] && [[ ${#ipv6_addresses[@]} -gt 0 ]]; then
    for addr_config in "${ipv6_addresses[@]}"; do
      addr_config=$(echo "$addr_config" | tr -s ' ' | sed 's/^ //;s/ $//')
      echo "Adding IPv6 config: $addr_config to ${bridge_name}"
      if ! ip addr add $addr_config dev ${bridge_name}; then
        echo "Error: Failed to add IPv6 configuration to ${bridge_name}"
        migration_failed=true
        break
      fi
    done
  fi

  # Add routes
  if [[ "$migration_failed" = false ]]; then
    # Delete default routes from source interface first
    if [[ -n "$ipv4_default_gw" ]]; then
      echo "Removing IPv4 default route from ${src_nic}..."
      ip -4 route del default dev ${src_nic} 2>/dev/null || true
    fi

    if [[ -n "$ipv6_default_gw" ]]; then
      echo "Removing IPv6 default route from ${src_nic}..."
      ip -6 route del default dev ${src_nic} 2>/dev/null || true
    fi

    # Add IPv4 routes
    for route_config in "${ipv4_routes[@]}"; do
      echo "Adding IPv4 route: $route_config via ${bridge_name}"
      ip -4 route add $route_config dev ${bridge_name} 2>/dev/null || true
    done

    # Add IPv6 routes
    for route_config in "${ipv6_routes[@]}"; do
      echo "Adding IPv6 route: $route_config via ${bridge_name}"
      ip -6 route add $route_config dev ${bridge_name} 2>/dev/null || true
    done

    # Add default gateways
    if [[ -n "$ipv4_default_gw" ]]; then
      echo "Adding IPv4 default gateway: ${ipv4_default_gw} via ${bridge_name}"
      if ! ip -4 route add default via ${ipv4_default_gw} dev ${bridge_name}; then
        echo "Warning: Failed to add IPv4 default gateway. Checking for conflicts..."
        existing_default=$(ip -4 route show default | head -n1)
        if [[ -n "$existing_default" ]]; then
          echo "Existing default route found: $existing_default"
        fi
      fi
    fi

    if [[ -n "$ipv6_default_gw" ]]; then
      echo "Adding IPv6 default gateway: ${ipv6_default_gw} via ${bridge_name}"
      if ! ip -6 route add default via ${ipv6_default_gw} dev ${bridge_name}; then
        echo "Warning: Failed to add IPv6 default gateway. Checking for conflicts..."
        existing_default=$(ip -6 route show default | head -n1)
        if [[ -n "$existing_default" ]]; then
          echo "Existing IPv6 default route found: $existing_default"
        fi
      fi
    fi
  fi

  # Finalize migration
  if [[ "$migration_failed" = false ]]; then
    echo "Successfully added all IP addresses and routes to ${bridge_name}. Flushing source interface ${src_nic}..."
    sleep 1
    ip addr flush dev ${src_nic}

    echo "Verifying routes for ${bridge_name}..."
    if ! ip route | grep -q "${bridge_name}"; then
      echo "Warning: No routes found for ${bridge_name}. This might cause connectivity issues."
    else
      echo "Routes for ${bridge_name} successfully configured."
    fi

    echo "Migration completed successfully!"
    echo ""
    echo "Bridge ${bridge_name} configuration:"
    ip addr show dev ${bridge_name}
    echo ""
    echo "IPv4 Routes:"
    ip -4 route show dev ${bridge_name}
    echo ""
    echo "IPv6 Routes:"
    ip -6 route show dev ${bridge_name}
  else
    # Rollback on failure
    echo "IP migration failed. Cleaning up bridge ${bridge_name}..."

    for addr_config in "${ipv4_addresses[@]}"; do
      ip_prefix=$(echo "$addr_config" | awk '{print $1}')
      ip addr del $ip_prefix dev ${bridge_name} 2>/dev/null || true
    done

    for addr_config in "${ipv6_addresses[@]}"; do
      ip_prefix=$(echo "$addr_config" | awk '{print $1}')
      ip addr del $ip_prefix dev ${bridge_name} 2>/dev/null || true
    done

    for route_config in "${ipv4_routes[@]}"; do
      ip -4 route del $route_config dev ${bridge_name} 2>/dev/null || true
    done

    for route_config in "${ipv6_routes[@]}"; do
      ip -6 route del $route_config dev ${bridge_name} 2>/dev/null || true
    done

    if [[ -n "$ipv4_default_gw" ]]; then
      ip -4 route del default via ${ipv4_default_gw} dev ${bridge_name} 2>/dev/null || true
    fi

    if [[ -n "$ipv6_default_gw" ]]; then
      ip -6 route del default via ${ipv6_default_gw} dev ${bridge_name} 2>/dev/null || true
    fi

    echo "Original interface ${src_nic} configuration preserved."
    exit 1
  fi

  set -e
}
