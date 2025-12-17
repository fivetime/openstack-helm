#!/bin/bash

set -ex

{{- if .Values.bgp.enabled }}

# 加载 IP 工具函数
source /tmp/ip-utils.sh

# ============================================================================
# ConfigMap 配置发现函数
# ============================================================================

# 从 ConfigMap 获取所有配置的网段
get_configured_subnets() {
    local mapping_file="/etc/ovn-bgp-agent/asn-mapping/mapping.json"

    if [ ! -f "$mapping_file" ]; then
        return 1
    fi

    # 获取所有非 example 的 key（网段）
    jq -r 'keys[] | select(startswith("_example_") | not)' "$mapping_file" 2>/dev/null
}

# 根据本地 IP 查找对应的 ConfigMap 配置
discover_leaf_config_by_ip() {
    local LOCAL_IPV4="$1"
    local mapping_file="/etc/ovn-bgp-agent/asn-mapping/mapping.json"

    if [ ! -f "$mapping_file" ]; then
        echo "ERROR: Mapping file not found: $mapping_file" >&2
        return 1
    fi

    if ! jq empty "$mapping_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in mapping file" >&2
        return 1
    fi

    # 遍历所有配置的网段，找到包含此 IP 的网段
    local configured_subnets
    configured_subnets=$(get_configured_subnets)

    local matched_subnet=""
    while IFS= read -r subnet; do
        [ -z "$subnet" ] && continue
        if ip_in_subnet "$LOCAL_IPV4" "$subnet"; then
            matched_subnet="$subnet"
            break
        fi
    done <<< "$configured_subnets"

    if [ -z "$matched_subnet" ]; then
        echo "ERROR: No configuration found for IP $LOCAL_IPV4" >&2
        echo "" >&2
        echo "Available subnets in ConfigMap:" >&2
        echo "$configured_subnets" | sed 's/^/  - /' >&2
        echo "" >&2
        echo "To add mapping:" >&2
        echo "  kubectl -n {{ .Release.Namespace }} edit configmap ovn-bgp-agent-asn" >&2
        return 1
    fi

    # 获取配置
    local config
    config=$(jq -r --arg subnet "$matched_subnet" '.[$subnet]' "$mapping_file")

    # 提取字段
    local asn ipv4_gw ipv6_gw description
    asn=$(echo "$config" | jq -r '.asn // empty')
    ipv4_gw=$(echo "$config" | jq -r '.ipv4 // empty')
    ipv6_gw=$(echo "$config" | jq -r '.ipv6 // empty')
    description=$(echo "$config" | jq -r '.desc // empty')

    if [ -z "$asn" ] || [ -z "$ipv4_gw" ]; then
        echo "ERROR: Invalid configuration for subnet $matched_subnet" >&2
        return 1
    fi

    # 返回: SUBNET|ASN|IPv4_GW|IPv6_GW|DESC
    echo "$matched_subnet|$asn|$ipv4_gw|$ipv6_gw|$description"
    return 0
}

# ============================================================================
# 主流程
# ============================================================================

NODE_NAME="${NODE_NAME:-$(hostname)}"

echo "=== BGP Configuration Discovery ==="
echo ""

# 步骤 1: 选择最佳 IPv4 地址
echo "Step 1: Selecting best IPv4 address..."

configured_subnets=$(get_configured_subnets)
LOCAL_IPV4=$(select_best_ipv4 "br-ex" "$configured_subnets")

if [ -z "$LOCAL_IPV4" ]; then
    echo "ERROR: Cannot determine local IPv4 address" >&2
    exit 1
fi

echo "  Selected: $LOCAL_IPV4"
echo ""

# 步骤 2: 根据本地 IP 查找配置
echo "Step 2: Looking up configuration for $LOCAL_IPV4..."

LEAF_CONFIG=$(discover_leaf_config_by_ip "$LOCAL_IPV4")

if [ -z "$LEAF_CONFIG" ]; then
    echo "ERROR: Failed to discover Leaf configuration" >&2
    exit 1
fi

# 解析配置
IFS='|' read -r LOCAL_SUBNET PEER_ASN PEER_IPV4 PEER_IPV6 LEAF_DESCRIPTION <<< "$LEAF_CONFIG"

if [ -z "$PEER_ASN" ] || [ -z "$PEER_IPV4" ]; then
    echo "ERROR: Invalid Leaf configuration" >&2
    exit 1
fi

echo "  Matched subnet: $LOCAL_SUBNET"
echo "  Peer ASN: $PEER_ASN"
echo "  Peer IPv4: $PEER_IPV4"
{{- if .Values.bgp.ipv6.enabled }}
echo "  Peer IPv6: ${PEER_IPV6:-Not configured}"
{{- end }}
echo ""

# 步骤 3: 生成本地 ASN 和 Router ID
echo "Step 3: Generating local BGP parameters..."

LOCAL_ASN=$(ip_to_asn "$LOCAL_IPV4")
ROUTER_ID="$LOCAL_IPV4"

echo "  Local ASN: $LOCAL_ASN (auto-generated)"
echo "  Router ID: $ROUTER_ID"
echo ""

# 步骤 4: 测试 IPv4 连通性
echo "Step 4: Testing IPv4 connectivity to peer..."

PEER_REACHABLE="no"
if test_ipv4_connectivity "$PEER_IPV4"; then
    PEER_REACHABLE="yes"
    echo "  Status: ✓ Reachable"
else
    echo "  Status: ✗ Not reachable"
fi
echo ""

{{- if .Values.bgp.ipv6.enabled }}
# 步骤 5: IPv6 配置
echo "Step 5: Configuring IPv6..."

# 验证 peer IPv6 配置
if [ -z "$PEER_IPV6" ] || [ "$PEER_IPV6" = "null" ]; then
    echo "ERROR: IPv6 enabled but no ipv6 configured for subnet $LOCAL_SUBNET" >&2
    echo "" >&2
    echo "Please edit the ConfigMap:" >&2
    echo "  kubectl -n {{ .Release.Namespace }} edit configmap ovn-bgp-agent-asn" >&2
    echo "" >&2
    echo "Add the 'ipv6' field to your subnet configuration:" >&2
    echo '  "'"$LOCAL_SUBNET"'": {' >&2
    echo '    "asn": "'"$PEER_ASN"'",' >&2
    echo '    "ipv4": "'"$PEER_IPV4"'",' >&2
    echo '    "ipv6": "fd00:1:2:3::1"  # <-- Add this' >&2
    echo '  }' >&2
    exit 1
fi

# 验证 peer IPv6 格式
if ! validate_ipv6_format "$PEER_IPV6"; then
    exit 1
fi

echo "  Peer IPv6: $PEER_IPV6"

# 选择本地 IPv6 地址
LOCAL_IPV6=$(select_best_ipv6 "br-ex" "$PEER_IPV6")

if [ -z "$LOCAL_IPV6" ]; then
    echo "ERROR: Cannot find usable IPv6 address on br-ex" >&2
    echo "" >&2
    echo "Current IPv6 addresses on br-ex:" >&2
    ip -6 addr show dev br-ex | grep inet6 | sed 's/^/  /' >&2
    echo "" >&2
    echo "Required: GUA (2xxx:) or ULA (fcxx:/fdxx:)" >&2
    exit 1
fi

echo "  Local IPv6: $LOCAL_IPV6"

# 测试 IPv6 连通性
PEER_IPV6_REACHABLE="no"
if test_ipv6_connectivity "$PEER_IPV6"; then
    PEER_IPV6_REACHABLE="yes"
    echo "  Status: ✓ Reachable"
else
    PEER_IPV6_REACHABLE="no"
    echo "  Status: ✗ Not reachable"
fi

export ENABLE_IPV6=true
export LOCAL_IPV6
export PEER_IPV6

echo ""

{{- else }}
export ENABLE_IPV6=false
{{- end }}

{{- if .Values.bgp.evpn.enabled }}
# 步骤 6: EVPN 配置
echo "Step 6: Configuring EVPN..."

EVPN_RR_IP="{{ .Values.bgp.evpn.rr_ip }}"
EVPN_RR_ASN="{{ .Values.bgp.evpn.rr_asn }}"

if [ -z "$EVPN_RR_IP" ] || [ -z "$EVPN_RR_ASN" ]; then
    echo "ERROR: EVPN enabled but rr_ip or rr_asn not configured" >&2
    exit 1
fi

echo "  RR IPv4: $EVPN_RR_IP"
echo "  RR ASN: $EVPN_RR_ASN"

EVPN_RR_REACHABLE="no"
if test_ipv4_connectivity "$EVPN_RR_IP"; then
    EVPN_RR_REACHABLE="yes"
    echo "  Status: ✓ Reachable"
else
    echo "  Status: ✗ Not reachable"
fi

export EVPN_RR_IP EVPN_RR_ASN EVPN_ENABLED=true

echo ""

{{- else }}
export EVPN_ENABLED=false
{{- end }}

# ============================================================================
# 配置摘要
# ============================================================================

cat <<EOF
=== BGP Configuration Summary ===
Node:           $NODE_NAME
Interface:      br-ex
Subnet:         $LOCAL_SUBNET
{{- if ne "$LEAF_DESCRIPTION" "" }}
Description:    ${LEAF_DESCRIPTION}
{{- end }}

Local (Server):
  IPv4:         $LOCAL_IPV4
  ASN:          $LOCAL_ASN (auto-generated)
  Router ID:    $ROUTER_ID
{{- if .Values.bgp.ipv6.enabled }}
  IPv6:         $LOCAL_IPV6
{{- end }}

Peer (Leaf Switch):
  ASN:          $PEER_ASN (from ConfigMap)
  IPv4:         $PEER_IPV4 (Status: $PEER_REACHABLE)
{{- if .Values.bgp.ipv6.enabled }}
  IPv6:         $PEER_IPV6 (Status: $PEER_IPV6_REACHABLE)
{{- end }}

{{- if .Values.bgp.evpn.enabled }}
EVPN Route Reflector:
  IPv4:         $EVPN_RR_IP
  ASN:          $EVPN_RR_ASN
  Status:       $EVPN_RR_REACHABLE
{{- end }}

=====================================

EOF

# 警告信息
if [ "$PEER_REACHABLE" != "yes" ]; then
    echo "WARNING: IPv4 peer $PEER_IPV4 is not reachable" >&2
    echo "         BGP session may fail to establish" >&2
fi

{{- if .Values.bgp.ipv6.enabled }}
if [ "$PEER_IPV6_REACHABLE" != "yes" ]; then
    echo "WARNING: IPv6 peer $PEER_IPV6 is not reachable" >&2
    echo "         BGP IPv6 session may fail to establish" >&2
fi
{{- end }}

{{- if .Values.bgp.evpn.enabled }}
if [ "$EVPN_RR_REACHABLE" != "yes" ]; then
    echo "WARNING: EVPN Route Reflector $EVPN_RR_IP is not reachable" >&2
fi
{{- end }}

# ============================================================================
# 导出配置并生成 FRR 配置
# ============================================================================

# 导出基础配置
export NODE_NAME
export LOCAL_IPV4
export LOCAL_ASN
export ROUTER_ID
export LOCAL_SUBNET
export PEER_ASN
export PEER_IPV4

# IPv6 配置已在上面 export，这里确保一致性
{{- if .Values.bgp.ipv6.enabled }}
# export ENABLE_IPV6=true
# export LOCAL_IPV6
# export PEER_IPV6
{{- else }}
# export ENABLE_IPV6=false
{{- end }}

# EVPN 配置已在上面 export，这里确保一致性
{{- if .Values.bgp.evpn.enabled }}
# export EVPN_ENABLED=true
# export EVPN_RR_IP
# export EVPN_RR_ASN
{{- else }}
# export EVPN_ENABLED=false
{{- end }}

# 生成 FRR 配置
/tmp/frr-config-gen.sh

echo ""
echo "FRR configuration initialized successfully"

# 导出给 ovn-bgp-agent
cat > /tmp/pod-shared/bgp-config.env << EOF
BGP_AS=$LOCAL_ASN
BGP_ROUTER_ID=$ROUTER_ID
LOCAL_SUBNET=$LOCAL_SUBNET
PEER_IPV4=$PEER_IPV4
{{- if .Values.bgp.evpn.enabled }}
EVPN_LOCAL_IP=$LOCAL_IPV4
{{- end }}
EOF

echo "BGP configuration exported to ovn-bgp-agent"

{{- else }}
echo "BGP is not enabled"
exit 0
{{- end }}