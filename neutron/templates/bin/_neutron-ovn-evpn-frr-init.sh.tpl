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

# ${GW6:<if>} / ${GW4:<if>} stand for this node's IPv6/IPv4 gateway on
# interface <if>, so one configuration peers every node with its own
# first-hop router: the next hop of the interface's default route, or else
# of its first route that has one.
gateway_of() {
  for routes in "default dev $2" "dev $2"; do
    gw=$(ip -"$1" route show ${routes} 2>/dev/null \
      | awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}')
    if [ -n "${gw}" ]; then
      echo "${gw}"
      return
    fi
  done
}
for token in $(grep -o '\${GW[46]:[A-Za-z0-9_.@-]*}' /etc/frr/frr.conf | sort -u); do
  family=${token#\$\{GW}
  family=${family%%:*}
  dev=${token#*:}
  dev=${dev%\}}
  gw=$(gateway_of "${family}" "${dev}")
  if [ -z "${gw}" ]; then
    echo "no IPv${family} gateway on ${dev} for ${token}" >&2
    exit 1
  fi
  pattern=$(printf '%s' "${token}" | sed 's/[$.]/\\&/g')
  sed -i "s|${pattern}|${gw}|g" /etc/frr/frr.conf
done

cp /tmp/ovn-evpn-frr-daemons /etc/frr/daemons
cp /tmp/ovn-evpn-frr-vtysh.conf /etc/frr/vtysh.conf
