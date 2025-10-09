#!/bin/bash

set -ex

{{- if .Values.bgp.enabled }}

# Convert IP address to ASN
ip_to_asn() {
    local ip="$1"
    IFS='.' read -r a b c d <<< "$ip"
    echo $((4200000000 + b * 65536 + c * 256 + d))
}

# Discover Leaf configuration from ConfigMap mapping
discover_leaf_config() {
    local local_subnet="$1"
    local mapping_file="/etc/ovn-bgp-agent/asn-mapping/mapping.json"

    if [ ! -f "$mapping_file" ]; then
        echo "ERROR: Leaf configuration mapping file not found: $mapping_file" >&2
        echo "Please ensure the ConfigMap 'ovn-bgp-agent-asn' exists" >&2
        return 1
    fi

    # Try to parse the mapping file
    if ! jq empty "$mapping_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in mapping file: $mapping_file" >&2
        return 1
    fi

    # Look up configuration for the subnet
    local config=$(jq -r --arg subnet "$local_subnet" '.[$subnet] // empty' "$mapping_file")

    if [ -z "$config" ] || [ "$config" = "null" ]; then
        echo "ERROR: No Leaf configuration found for subnet: $local_subnet" >&2
        echo "" >&2
        echo "Available mappings in ConfigMap:" >&2
        jq -r 'to_entries[] | select(.key | startswith("_example_") | not) | "  \(.key) -> AS\(.value.asn) (IPv4: \(.value.ipv4_gateway), IPv6: \(.value.ipv6_gateway // "N/A"))"' "$mapping_file" >&2
        echo "" >&2
        echo "To add a mapping, edit the ConfigMap:" >&2
        echo "  kubectl -n {{ .Release.Namespace }} edit configmap ovn-bgp-agent-asn" >&2
        return 1
    fi

    # Extract ASN
    local asn=$(echo "$config" | jq -r '.asn // empty')
    if [ -z "$asn" ]; then
        echo "ERROR: ASN not found in configuration for subnet: $local_subnet" >&2
        return 1
    fi

    # Extract IPv4 gateway (required)
    local ipv4_gw=$(echo "$config" | jq -r '.ipv4_gateway // empty')
    if [ -z "$ipv4_gw" ]; then
        echo "ERROR: ipv4_gateway not found in configuration for subnet: $local_subnet" >&2
        return 1
    fi

    # Extract IPv6 gateway (required if IPv6 enabled)
    local ipv6_gw=$(echo "$config" | jq -r '.ipv6_gateway // empty')

    # Extract description (optional)
    local description=$(echo "$config" | jq -r '.description // empty')

    # Return as space-separated values: ASN IPv4_GW IPv6_GW DESCRIPTION
    echo "$asn|$ipv4_gw|$ipv6_gw|$description"
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

# Discover Leaf configuration from ConfigMap
LEAF_CONFIG=$(discover_leaf_config "$LOCAL_SUBNET")
if [ -z "$LEAF_CONFIG" ]; then
    echo "ERROR: Failed to discover Leaf configuration for subnet $LOCAL_SUBNET"
    exit 1
fi

# Parse the configuration (use | as delimiter to handle empty fields)
IFS='|' read -r PEER_ASN PEER_IPV4 PEER_IPV6 LEAF_DESCRIPTION <<< "$LEAF_CONFIG"

if [ -z "$PEER_ASN" ] || [ -z "$PEER_IPV4" ]; then
    echo "ERROR: Invalid Leaf configuration for subnet $LOCAL_SUBNET"
    exit 1
fi

# Verify Leaf IPv4 connectivity
PEER_REACHABLE="unknown"
if ping -c 2 -W 2 "$PEER_IPV4" >/dev/null 2>&1; then
    PEER_REACHABLE="yes"
else
    PEER_REACHABLE="no"
fi

{{- if .Values.bgp.ipv6.enabled }}
# Verify IPv6 configuration
if [ -z "$PEER_IPV6" ] || [ "$PEER_IPV6" = "null" ]; then
    echo "ERROR: IPv6 enabled but no ipv6_gateway configured for subnet $LOCAL_SUBNET"
    echo "Please edit the ConfigMap and add ipv6_gateway for this subnet:"
    echo "  kubectl -n {{ .Release.Namespace }} edit configmap ovn-bgp-agent-asn"
    exit 1
fi

# Verify IPv6 connectivity
PEER_IPV6_REACHABLE="unknown"
if ping6 -c 2 -W 2 "$PEER_IPV6" >/dev/null 2>&1; then
    PEER_IPV6_REACHABLE="yes"
else
    PEER_IPV6_REACHABLE="no"
fi
{{- end }}

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
{{- if ne "$LEAF_DESCRIPTION" "" }}
Description:    $LEAF_DESCRIPTION
{{- end }}

Local (Server):
  IPv4:         $LOCAL_IP
  ASN:          $LOCAL_ASN (auto-generated from IP)
  Router ID:    $ROUTER_ID

Peer (Leaf Switch):
  ASN:          $PEER_ASN (from ConfigMap)
  IPv4:         $PEER_IPV4 (from ConfigMap)
  IPv4 Status:  $PEER_REACHABLE
{{- if .Values.bgp.ipv6.enabled }}
  IPv6:         $PEER_IPV6 (from ConfigMap)
  IPv6 Status:  $PEER_IPV6_REACHABLE
{{- end }}

{{- if .Values.bgp.ipv6.enabled }}
BGP Sessions:
  Mode:         Dual-Stack
  IPv4 Session: $LOCAL_IP <-> $PEER_IPV4
  IPv6 Session: (local IPv6) <-> $PEER_IPV6
{{- else }}
BGP Sessions:
  Mode:         IPv4 Only
  IPv4 Session: $LOCAL_IP <-> $PEER_IPV4
{{- end }}

{{- if .Values.bgp.evpn.enabled }}
EVPN Route Reflector:
  IPv4:         $EVPN_RR_IP
  ASN:          $EVPN_RR_ASN
  Reachable:    $EVPN_RR_REACHABLE
{{- end }}

==================================

EOF

# Warning messages
if [ "$PEER_REACHABLE" != "yes" ]; then
    echo "WARNING: Leaf switch IPv4 $PEER_IPV4 is not reachable"
    echo "         BGP session will not establish until connectivity is restored"
fi

{{- if .Values.bgp.ipv6.enabled }}
if [ "$PEER_IPV6_REACHABLE" != "yes" ]; then
    echo "WARNING: Leaf switch IPv6 $PEER_IPV6 is not reachable"
    echo "         IPv6 BGP session will not establish until connectivity is restored"
fi
{{- end }}

{{- if .Values.bgp.evpn.enabled }}
if [ "$EVPN_RR_REACHABLE" != "yes" ]; then
    echo "WARNING: EVPN Route Reflector $EVPN_RR_IP is not reachable"
fi
{{- end }}

# Export configuration for FRR
export NODE_NAME LOCAL_IP LOCAL_ASN ROUTER_ID
export PEER_IPV4 PEER_ASN
{{- if .Values.bgp.ipv6.enabled }}
export ENABLE_IPV6=true
export PEER_IPV6
{{- else }}
export ENABLE_IPV6=false
{{- end }}
{{- if .Values.bgp.evpn.enabled }}
export EVPN_RR_IP EVPN_RR_ASN EVPN_ENABLED=true
{{- else }}
export EVPN_ENABLED=false
{{- end }}

# Generate FRR configuration
/tmp/frr-config-gen.sh

echo "FRR configuration initialized successfully"

# Export to shared file for ovn-bgp-agent
cat > /tmp/pod-shared/bgp-config.env <<EOF
BGP_AS=$LOCAL_ASN
BGP_ROUTER_ID=$ROUTER_ID
EOF

echo "BGP configuration exported to /tmp/pod-shared/bgp-config.env"
{{- else }}
echo "BGP is not enabled"
exit 0
{{- end }}