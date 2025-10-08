#!/bin/bash
set -ex

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
if grep -q "^bgp_AS" /tmp/ovn-bgp-agent.conf; then
    sed -i "s/^bgp_AS.*/bgp_AS = $BGP_AS/" /tmp/ovn-bgp-agent.conf
else
    sed -i "/^\[DEFAULT\]/a bgp_AS = $BGP_AS" /tmp/ovn-bgp-agent.conf
fi

if grep -q "^bgp_router_id" /tmp/ovn-bgp-agent.conf; then
    sed -i "s/^bgp_router_id.*/bgp_router_id = $BGP_ROUTER_ID/" /tmp/ovn-bgp-agent.conf
else
    sed -i "/^\[DEFAULT\]/a bgp_router_id = $BGP_ROUTER_ID" /tmp/ovn-bgp-agent.conf
fi

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