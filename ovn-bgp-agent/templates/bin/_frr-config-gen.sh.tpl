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

# Create FRR configuration directory
mkdir -p /etc/frr

# Generate daemons file
cat > /etc/frr/daemons <<'DAEMONS_EOF'
bgpd=yes
zebra=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no

zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
DAEMONS_EOF

# Generate main configuration file
cat > /etc/frr/frr.conf <<MAIN_EOF
frr defaults traditional
hostname ${NODE_NAME}
log syslog informational
service integrated-vtysh-config
!
ip router-id ${ROUTER_ID}
!
router bgp ${LOCAL_ASN}
 bgp router-id ${ROUTER_ID}
 bgp log-neighbor-changes
 bgp graceful-restart
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
MAIN_EOF

# 添加 Leaf 对等体配置
cat >> /etc/frr/frr.conf <<PEER_EOF
 !
 ! eBGP Peering to Leaf Switch
 neighbor ${PEER_IPV4} remote-as ${PEER_ASN}
 neighbor ${PEER_IPV4} description "Leaf-Switch"
 neighbor ${PEER_IPV4} timers 3 10
 neighbor ${PEER_IPV4} timers connect 10
PEER_EOF

# 如果启用 EVPN,添加 RR 对等体
if [ "$EVPN_ENABLED" = "true" ]; then
    cat >> /etc/frr/frr.conf <<EVPN_PEER_EOF
 !
 ! iBGP to EVPN Route Reflector
 neighbor ${EVPN_RR_IP} remote-as ${EVPN_RR_ASN}
 neighbor ${EVPN_RR_IP} description "EVPN-Route-Reflector"
 neighbor ${EVPN_RR_IP} update-source ${LOCAL_IP}
 neighbor ${EVPN_RR_IP} timers 3 10
 neighbor ${EVPN_RR_IP} timers connect 10
EVPN_PEER_EOF
fi

# 添加 IPv4 Unicast address-family
cat >> /etc/frr/frr.conf <<IPV4_AF_EOF
 !
 address-family ipv4 unicast
  neighbor ${PEER_IPV4} activate
  neighbor ${PEER_IPV4} soft-reconfiguration inbound
 exit-address-family
IPV4_AF_EOF

# 如果启用 EVPN,添加 L2VPN EVPN address-family
if [ "$EVPN_ENABLED" = "true" ]; then
    cat >> /etc/frr/frr.conf <<EVPN_AF_EOF
 !
 address-family l2vpn evpn
  neighbor ${EVPN_RR_IP} activate
  advertise-all-vni
 exit-address-family
EVPN_AF_EOF
fi

# 完成配置
cat >> /etc/frr/frr.conf <<FOOTER_EOF
!
line vty
!
FOOTER_EOF

# 生成 vtysh 配置
cat > /etc/frr/vtysh.conf <<'VTYSH_EOF'
service integrated-vtysh-config
VTYSH_EOF

# 设置文件权限
chmod 640 /etc/frr/frr.conf
chmod 640 /etc/frr/daemons
chmod 644 /etc/frr/vtysh.conf

echo "FRR configuration files created:"
echo "  /etc/frr/daemons"
echo "  /etc/frr/frr.conf"
echo "  /etc/frr/vtysh.conf"