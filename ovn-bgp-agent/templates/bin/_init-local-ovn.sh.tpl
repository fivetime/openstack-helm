#!/bin/bash

{{- $bgpChassisId := .Values.conf.ovn_bgp_agent.local_ovn_cluster.bgp_chassis_id | default "bgp" }}

set -ex

echo "=== Initializing Local OVN Cluster ==="

# Create directories
mkdir -p /etc/ovn /var/run/ovn /var/log/ovn

# Initialize OVN Northbound database
if [ ! -f /etc/ovn/ovnnb_db.db ]; then
    echo "Creating OVN Northbound database..."
    ovsdb-tool create /etc/ovn/ovnnb_db.db /usr/share/ovn/ovn-nb.ovsschema
    echo "OVN NB database created"
else
    echo "OVN NB database already exists"
fi

# Initialize OVN Southbound database
if [ ! -f /etc/ovn/ovnsb_db.db ]; then
    echo "Creating OVN Southbound database..."
    ovsdb-tool create /etc/ovn/ovnsb_db.db /usr/share/ovn/ovn-sb.ovsschema
    echo "OVN SB database created"
else
    echo "OVN SB database already exists"
fi

# Set permissions
chown -R openvswitch:openvswitch /etc/ovn /var/run/ovn /var/log/ovn

echo "=== Local OVN Cluster Initialized ==="
echo "  NB DB: /etc/ovn/ovnnb_db.db"
echo "  SB DB: /etc/ovn/ovnsb_db.db"
echo "  Chassis ID: {{ $bgpChassisId }}"
echo "=================================="