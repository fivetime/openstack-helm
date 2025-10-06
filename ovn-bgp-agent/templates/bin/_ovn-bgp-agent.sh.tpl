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

# Wait for FRR to be ready
echo "Waiting for FRR to be ready..."
timeout=60
counter=0
until [ -S /run/frr/zebra.vty ] || [ $counter -eq $timeout ]; do
    sleep 1
    ((counter++))
done

if [ $counter -eq $timeout ]; then
    echo "ERROR: FRR did not become ready in time"
    exit 1
fi

echo "FRR is ready"

# Wait for OVN databases to be accessible
echo "Checking OVN NB database connectivity..."
timeout=120
counter=0
until ovn-nbctl --db="$OVN_NB_CONNECTION" show >/dev/null 2>&1 || [ $counter -eq $timeout ]; do
    echo "Waiting for OVN NB database at $OVN_NB_CONNECTION..."
    sleep 2
    ((counter++))
done

if [ $counter -eq $timeout ]; then
    echo "ERROR: OVN NB database not accessible"
    exit 1
fi

echo "OVN NB database is accessible"

echo "Checking OVN SB database connectivity..."
counter=0
until ovn-sbctl --db="$OVN_SB_CONNECTION" show >/dev/null 2>&1 || [ $counter -eq $timeout ]; do
    echo "Waiting for OVN SB database at $OVN_SB_CONNECTION..."
    sleep 2
    ((counter++))
done

if [ $counter -eq $timeout ]; then
    echo "ERROR: OVN SB database not accessible"
    exit 1
fi

echo "OVN SB database is accessible"

# Create log directory
mkdir -p /var/log/ovn-bgp-agent

# Update configuration with runtime values
sed -i "s|^ovn_nb_connection.*|ovn_nb_connection = $OVN_NB_CONNECTION|" /etc/ovn-bgp-agent/ovn-bgp-agent.conf
sed -i "s|^ovn_sb_connection.*|ovn_sb_connection = $OVN_SB_CONNECTION|" /etc/ovn-bgp-agent/ovn-bgp-agent.conf

# Mark as ready
touch /tmp/pod-shared/ready

# Start the agent
exec /usr/local/bin/ovn-bgp-agent \
    --config-file /etc/ovn-bgp-agent/ovn-bgp-agent.conf \
    --log-file /var/log/ovn-bgp-agent/ovn-bgp-agent.log