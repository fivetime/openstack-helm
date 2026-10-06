#!/bin/sh

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

# The OVN agent's ovn-evpn extension reuses an existing BGP instance only if
# its router-id is this chassis' ovn-evpn-local-ip, so FRR takes it from the
# same place the agent does.
ROUTER_ID=$(ovs-vsctl --no-wait --if-exists get Open_vSwitch . \
    external_ids:ovn-evpn-local-ip | tr -d '"')
if [ -z "${ROUTER_ID}" ]; then
  echo "external_ids:ovn-evpn-local-ip is not set on this chassis" >&2
  exit 1
fi
case "${ROUTER_ID}" in
  *:*)
    echo "ovn-evpn-local-ip ${ROUTER_ID} is not IPv4; a BGP router-id must be" >&2
    exit 1
    ;;
esac

HOSTNAME=$(hostname -s)
sed -e "s|\${ROUTER_ID}|${ROUTER_ID}|g" \
    -e "s|\${HOSTNAME}|${HOSTNAME}|g" \
    /tmp/ovn-evpn-frr.conf.in > /etc/frr/frr.conf
cp /tmp/ovn-evpn-frr-daemons /etc/frr/daemons
cp /tmp/ovn-evpn-frr-vtysh.conf /etc/frr/vtysh.conf
