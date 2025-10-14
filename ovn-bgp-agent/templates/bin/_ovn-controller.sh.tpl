#!/bin/bash
{{- $bgpChassisId := .Values.conf.ovn_bgp_agent.local_ovn_cluster.bgp_chassis_id | default "bgp" }}
set -ex

# Wait for SB socket
until [ -S /var/run/ovn/ovnsb_db.sock ]; do
    echo "Waiting for OVN SB socket..."
    sleep 2
done

# Verify SB is responsive
until ovn-sbctl --timeout=3 --db=unix:/var/run/ovn/ovnsb_db.sock show > /dev/null 2>&1; do
    echo "Waiting for OVN SB to respond..."
    sleep 2
done

echo "=== Configuring OVS for Local OVN ==="

# Configure OVS external-ids
ovs-vsctl set open . external-ids:ovn-bridge-{{ $bgpChassisId }}=br-bgp
ovs-vsctl set open . external-ids:ovn-remote-{{ $bgpChassisId }}=unix:/var/run/ovn/ovnsb_db.sock
ovs-vsctl set open . external-ids:ovn-encap-ip-{{ $bgpChassisId }}=127.0.0.1
ovs-vsctl set open . external-ids:ovn-encap-type=geneve

echo "OVS configured for chassis ID: {{ $bgpChassisId }}"

# Start ovn-controller in foreground
exec ovn-controller \
    -n {{ $bgpChassisId }} \
    --log-file=/var/log/ovn/ovn-controller-{{ $bgpChassisId }}.log \
    unix:/var/run/openvswitch/db.sock