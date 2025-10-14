#!/bin/bash
set -ex

{{- $isOvnMode := eq (.Values.conf.ovn_bgp_agent.DEFAULT.exposing_method | default "underlay") "ovn" }}

{{- if $isOvnMode }}
# Wait for local OVN cluster to be ready
echo "Waiting for local OVN cluster..."
timeout=120
counter=0
until [ -S /var/run/ovn/ovnnb_db.sock ] && [ -S /var/run/ovn/ovnsb_db.sock ]; do
    if [ $counter -eq $timeout ]; then
        echo "ERROR: Local OVN cluster not ready after ${timeout}s"
        exit 1
    fi
    sleep 1
    ((counter++))
done

# Verify OVN NB is accessible
until ovn-nbctl --timeout=3 --db=unix:/var/run/ovn/ovnnb_db.sock show > /dev/null 2>&1; do
    echo "Waiting for OVN NB to respond..."
    sleep 2
done

echo "Local OVN cluster is ready"
{{- end }}

# Wait for FRR init
timeout=60
counter=0
until [ -f /tmp/pod-shared/bgp-config.env ] || [ $counter -eq $timeout ]; do
    sleep 1
    ((counter++))
done

if [ ! -f /tmp/pod-shared/bgp-config.env ]; then
    echo "ERROR: BGP config not found"
    exit 1
fi

# Load BGP config
source /tmp/pod-shared/bgp-config.env

# Update config file
cp /etc/ovn-bgp-agent/ovn-bgp-agent.conf /tmp/ovn-bgp-agent.conf

# Update bgp_AS
if grep -q "^bgp_AS" /tmp/ovn-bgp-agent.conf; then
    sed -i "s/^bgp_AS.*/bgp_AS = $BGP_AS/" /tmp/ovn-bgp-agent.conf
else
    sed -i "/^\[DEFAULT\]/a bgp_AS = $BGP_AS" /tmp/ovn-bgp-agent.conf
fi

# Update bgp_router_id
if grep -q "^bgp_router_id" /tmp/ovn-bgp-agent.conf; then
    sed -i "s/^bgp_router_id.*/bgp_router_id = $BGP_ROUTER_ID/" /tmp/ovn-bgp-agent.conf
else
    sed -i "/^\[DEFAULT\]/a bgp_router_id = $BGP_ROUTER_ID" /tmp/ovn-bgp-agent.conf
fi

{{- if .Values.bgp.evpn.enabled }}
# Update evpn_local_ip
if grep -q "^evpn_local_ip" /tmp/ovn-bgp-agent.conf; then
    sed -i "s/^evpn_local_ip.*/evpn_local_ip = $EVPN_LOCAL_IP/" /tmp/ovn-bgp-agent.conf
else
    sed -i "/^\[DEFAULT\]/a evpn_local_ip = $EVPN_LOCAL_IP" /tmp/ovn-bgp-agent.conf
fi
{{- end }}

{{- if $isOvnMode }}
# Update peer_ips in [local_ovn_cluster] section
if grep -q "^peer_ips" /tmp/ovn-bgp-agent.conf; then
    sed -i "s|^peer_ips.*|peer_ips = $PEER_IPV4|" /tmp/ovn-bgp-agent.conf
else
    sed -i "/^\[local_ovn_cluster\]/a peer_ips = $PEER_IPV4" /tmp/ovn-bgp-agent.conf
fi

# Update provider_networks_pool_prefixes in [local_ovn_cluster] section
if grep -q "^provider_networks_pool_prefixes" /tmp/ovn-bgp-agent.conf; then
    sed -i "s|^provider_networks_pool_prefixes.*|provider_networks_pool_prefixes = $LOCAL_SUBNET|" /tmp/ovn-bgp-agent.conf
else
    sed -i "/^\[local_ovn_cluster\]/a provider_networks_pool_prefixes = $LOCAL_SUBNET" /tmp/ovn-bgp-agent.conf
fi
{{- end }}

# Dynamically set routing table ID
BR_EX_TABLE_ID=$(grep "br-ex" /etc/iproute2/rt_tables | awk '{print $1}')
if [ -n "$BR_EX_TABLE_ID" ]; then
    sed -i '/^bgp_vrf_table_id/d' /tmp/ovn-bgp-agent.conf
    sed -i "/^\[DEFAULT\]/a bgp_vrf_table_id = $BR_EX_TABLE_ID" /tmp/ovn-bgp-agent.conf
fi

# Wait for FRR ready
timeout=60
counter=0
until [ -S /run/frr/zebra.vty ] || [ $counter -eq $timeout ]; do
    sleep 1
    ((counter++))
done

mkdir -p /var/log/ovn-bgp-agent
touch /tmp/pod-shared/ready

# Debug: show config if debug enabled
if grep -q "^debug = [Tt]rue" /etc/ovn-bgp-agent/ovn-bgp-agent.conf 2>/dev/null; then
    echo "=== OVN BGP Agent Configuration ==="
    cat /tmp/ovn-bgp-agent.conf
    echo "==================================="
fi

exec /install/local/bin/ovn-bgp-agent \
    --config-file /tmp/ovn-bgp-agent.conf