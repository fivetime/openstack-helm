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

HOSTNAME=$(hostname -s)
PORTNAME=octavia-worker-port-$HOSTNAME

if ! PORT_JSON=$(openstack port show ${PORTNAME} -f json 2>/dev/null); then
    echo "ERROR: port ${PORTNAME} does not exist"
    exit 1
fi

# JSON parsing, not grep: a port with the DNS extension carries two
# "ip_address" matches (fixed_ips and dns_assignment) and grep takes both,
# which produced `ip addr add A A/24` and a crash loop naming neither the
# field nor the cause. Same defect the health-manager script had.
eval "$(echo "$PORT_JSON" | python3 -c '
import json, sys
p = json.load(sys.stdin)
fixed = (p.get("fixed_ips") or [{}])[0]
print("PORT_ID=%s" % p.get("id", ""))
print("PORT_MAC=%s" % p.get("mac_address", ""))
print("PORT_IP=%s" % fixed.get("ip_address", ""))
print("SUBNET_ID=%s" % fixed.get("subnet_id", ""))
')"

if [ -z "${PORT_IP}" ] || [ -z "${SUBNET_ID}" ]; then
    echo "ERROR: could not read an address or subnet from ${PORTNAME}"
    exit 1
fi

SUBNET_JSON=$(openstack subnet show ${SUBNET_ID} -f json)
eval "$(echo "$SUBNET_JSON" | python3 -c '
import json, sys
n = json.load(sys.stdin)
print("SUBNET_CIDR=%s" % n.get("cidr", ""))
')"
SUBNET_MASK=$(echo $SUBNET_CIDR | cut -d"/" -f2)

echo "port ${PORT_IP}/${SUBNET_MASK} on ${PORTNAME}"

echo $PORT_ID    > /tmp/pod-shared/HM_PORT_ID
echo $PORT_MAC   > /tmp/pod-shared/HM_PORT_MAC
echo $PORT_IP    > /tmp/pod-shared/HM_PORT_IP
echo $SUBNET_ID  > /tmp/pod-shared/HM_SUBNET_ID
echo $SUBNET_CIDR > /tmp/pod-shared/HM_SUBNET_CIDR
echo $SUBNET_MASK > /tmp/pod-shared/HM_SUBNET_MASK
