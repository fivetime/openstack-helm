#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -ex

{{- if .Values.bgp.enabled }}

# Convert IP address to ASN
ip_to_asn() {
    local ip="$1"
    IFS='.' read -r a b c d <<< "$ip"
    echo $((4200000000 + b * 65536 + c * 256 + d))
}

# Calculate subnet information
get_subnet_info() {
    local ip_cidr="$1"
    local ip="${ip_cidr%/*}"
    local prefix="${ip_cidr#*/}"

    IFS='.' read -r a b c d <<< "$ip"
    local ip_int=$((a * 16777216 + b * 65536 + c * 256 + d))

    local mask=$((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))
    local network=$((ip_int & mask))
    local broadcast=$((network | (~mask & 0xFFFFFFFF)))

    local first=$((network + 1))
    local last=$((broadcast - 1))

    local first_ip="$((first >> 24 & 0xFF)).$((first >> 16 & 0xFF)).$((first >> 8 & 0xFF)).$((first & 0xFF))"
    local last_ip="$((last >> 24 & 0xFF)).$((last >> 16 & 0xFF)).$((last >> 8 & 0xFF)).$((last & 0xFF))"

    echo "$first_ip $last_ip"
}

# Discover gateway from routing table
discover_from_route() {
    local interface="$1"
    ip -4 route show dev "$interface" 2>/dev/null | \
        grep '^default' | awk '{print $3}' | head -n1
}

# Discover gateway via ARP scanning
discover_from_arp() {
    local interface="$1"
    local ip_cidr="$2"

    read -r first_ip last_ip <<< "$(get_subnet_info "$ip_cidr")"

    for gw in "$first_ip" "$last_ip"; do
        ping -c 1 -W 1 "$gw" >/dev/null 2>&1 &
    done
    wait
    sleep 1

    for gw in "$first_ip" "$last_ip"; do
        if ip neigh show dev "$interface" | grep -q "^${gw} "; then
            echo "$gw"
            return 0
        fi
    done

    return 1
}

# Auto-detect gateway with fallback
discover_gateway_auto() {
    local interface="$1"
    local ip_cidr="$2"

    local gw=$(discover_from_route "$interface")
    if [ -n "$gw" ]; then
        echo "$gw detection:route"
        return 0
    fi

    gw=$(discover_from_arp "$interface" "$ip_cidr")
    if [ -n "$gw" ]; then
        echo "$gw detection:arp"
        return 0
    fi

    read first_ip last_ip <<< $(get_subnet_info "$ip_cidr")
    echo "$first_ip detection:fallback"
    return 0
}

# Discover Leaf ASN from ConfigMap mapping
discover_leaf_asn() {
    local local_subnet="$1"
    local mapping_file="/etc/ovn-bgp-agent/asn-mapping/mapping.json"

    if [ ! -f "$mapping_file" ]; then
        echo "ERROR: Leaf ASN mapping file not found: $mapping_file" >&2
        echo "Please ensure the ConfigMap 'ovn-bgp-agent-asn' exists" >&2
        return 1
    fi

    # Try to parse the mapping file
    if ! jq empty "$mapping_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in mapping file: $mapping_file" >&2
        return 1
    fi

    # Look up ASN for the subnet
    local asn=$(jq -r --arg subnet "$local_subnet" '.[$subnet] // empty' "$mapping_file")

    if [ -z "$asn" ]; then
        echo "ERROR: No Leaf ASN mapping found for subnet: $local_subnet" >&2
        echo "" >&2
        echo "Available mappings in ConfigMap:" >&2
        jq -r 'to_entries[] | select(.key | startswith("_example_") | not) | "  \(.key) -> AS\(.value)"' "$mapping_file" >&2
        echo "" >&2
        echo "To add a mapping, edit the ConfigMap:" >&2
        echo "  kubectl -n {{ .Release.Namespace }} edit configmap ovn-bgp-agent-asn" >&2
        return 1
    fi

    echo "$asn"
}

# Get local node information
NODE_NAME="${NODE_NAME:-$(hostname)}"
LOCAL_IPV4=$(ip -4 addr show br-ex 2>/dev/null | \
    grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)

if [ -z "$LOCAL_IPV4" ]; then
    echo "ERROR: Cannot get IPv4 address from br-ex interface"
    exit 1
fi

LOCAL_IP="${LOCAL_IPV4%/*}"
LOCAL_ASN=$(ip_to_asn "$LOCAL_IP")
ROUTER_ID="$LOCAL_IP"

# Get local subnet
LOCAL_SUBNET=$(ip -4 route show dev br-ex | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/ {print $1; exit}')

if [ -z "$LOCAL_SUBNET" ]; then
    echo "ERROR: Cannot determine local subnet from br-ex interface"
    exit 1
fi

# Get Leaf peer IP configuration
PEER_CONFIG="{{ .Values.bgp.peer_ip }}"

if [ -z "$PEER_CONFIG" ] || [ "$PEER_CONFIG" = "detection" ]; then
    read PEER_IPV4 DISCOVERY_METHOD <<< $(discover_gateway_auto "br-ex" "$LOCAL_IPV4")
elif [ "$PEER_CONFIG" = "first" ]; then
    read first_ip last_ip <<< $(get_subnet_info "$LOCAL_IPV4")
    PEER_IPV4="$first_ip"
    DISCOVERY_METHOD="first"
elif [ "$PEER_CONFIG" = "last" ]; then
    read first_ip last_ip <<< $(get_subnet_info "$LOCAL_IPV4")
    PEER_IPV4="$last_ip"
    DISCOVERY_METHOD="last"
else
    PEER_IPV4="$PEER_CONFIG"
    DISCOVERY_METHOD="manual"
fi

# Discover Leaf ASN from ConfigMap
PEER_ASN=$(discover_leaf_asn "$LOCAL_SUBNET")
if [ -z "$PEER_ASN" ]; then
    echo "ERROR: Failed to discover Leaf ASN for subnet $LOCAL_SUBNET"
    exit 1
fi

# Verify Leaf connectivity
PEER_REACHABLE="unknown"
if ping -c 2 -W 2 "$PEER_IPV4" >/dev/null 2>&1; then
    PEER_REACHABLE="yes"
else
    PEER_REACHABLE="no"
fi

{{- if .Values.bgp.evpn.enabled }}
# EVPN Route Reflector configuration
EVPN_RR_IP="{{ .Values.bgp.evpn.rr_ip }}"
EVPN_RR_ASN="{{ .Values.bgp.evpn.rr_asn }}"

if [ -z "$EVPN_RR_IP" ] || [ -z "$EVPN_RR_ASN" ]; then
    echo "ERROR: EVPN enabled but rr_ip or rr_asn not configured"
    exit 1
fi

# Verify RR connectivity
EVPN_RR_REACHABLE="unknown"
if ping -c 2 -W 2 "$EVPN_RR_IP" >/dev/null 2>&1; then
    EVPN_RR_REACHABLE="yes"
else
    EVPN_RR_REACHABLE="no"
fi
{{- end }}

# Print configuration summary
cat <<EOF

=== BGP Configuration ===
Node:           $NODE_NAME
Interface:      br-ex ($LOCAL_IPV4)
Subnet:         $LOCAL_SUBNET

Local (Server):
  IPv4:         $LOCAL_IP
  ASN:          $LOCAL_ASN (auto-generated)
  Router ID:    $ROUTER_ID

Peer (Leaf Switch):
  IPv4:         $PEER_IPV4
  ASN:          $PEER_ASN (from ConfigMap)
  Discovery:    $DISCOVERY_METHOD
  Reachable:    $PEER_REACHABLE

{{- if .Values.bgp.evpn.enabled }}
EVPN Route Reflector:
  IPv4:         $EVPN_RR_IP
  ASN:          $EVPN_RR_ASN
  Reachable:    $EVPN_RR_REACHABLE
{{- end }}

==================================

EOF

if [ "$PEER_REACHABLE" != "yes" ]; then
    echo "WARNING: Leaf switch $PEER_IPV4 is not reachable"
fi

{{- if .Values.bgp.evpn.enabled }}
if [ "$EVPN_RR_REACHABLE" != "yes" ]; then
    echo "WARNING: EVPN Route Reflector $EVPN_RR_IP is not reachable"
fi
{{- end }}

# Export configuration for FRR
export NODE_NAME LOCAL_IP LOCAL_ASN ROUTER_ID
export PEER_IPV4 PEER_ASN
{{- if .Values.bgp.evpn.enabled }}
export EVPN_RR_IP EVPN_RR_ASN EVPN_ENABLED=true
{{- else }}
export EVPN_ENABLED=false
{{- end }}

# Generate FRR configuration
/tmp/frr-config-gen.sh

echo "FRR configuration initialized successfully"

{{- else }}
echo "BGP is not enabled"
exit 0
{{- end }}