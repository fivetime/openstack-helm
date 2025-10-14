#!/bin/bash

set -ex

# Create FRR configuration directory
mkdir -p /etc/frr

# Generate daemons file
cat > /etc/frr/daemons <<'DAEMONS_EOF'
bgpd=yes
bfdd=yes
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
fabricd=no
vrrpd=no

bgpd_options="   -A 127.0.0.1"
zebra_options="  -A 127.0.0.1 -s 90000000"
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

# 添加 IPv4 Leaf 对等体配置
cat >> /etc/frr/frr.conf <<PEER_IPV4_EOF
 !
 ! eBGP Peering to Leaf Switch (IPv4)
 neighbor LEAF-IPV4 peer-group
 neighbor LEAF-IPV4 remote-as ${PEER_ASN}
 neighbor LEAF-IPV4 description "LEAF-IPv4"
 neighbor LEAF-IPV4 update-source br-ex
 neighbor LEAF-IPV4 send-community all
 neighbor LEAF-IPV4 ebgp-multihop 10
 neighbor LEAF-IPV4 bfd
 neighbor LEAF-IPV4 timers 3 10
 neighbor LEAF-IPV4 timers connect 10
 !
 neighbor ${PEER_IPV4} peer-group LEAF-IPV4
PEER_IPV4_EOF

# 如果启用 IPv6，添加 IPv6 Leaf 对等体配置
if [ "${ENABLE_IPV6:-false}" = "true" ]; then
    cat >> /etc/frr/frr.conf <<PEER_IPV6_EOF
 !
 ! eBGP Peering to Leaf Switch (IPv6)
 neighbor LEAF-IPV6 peer-group
 neighbor LEAF-IPV6 remote-as ${PEER_ASN}
 neighbor LEAF-IPV6 description "LEAF-IPv6"
 neighbor LEAF-IPV6 update-source br-ex
 neighbor LEAF-IPV6 send-community all
 neighbor LEAF-IPV6 ebgp-multihop 10
 neighbor LEAF-IPV6 bfd
 neighbor LEAF-IPV6 timers 3 10
 neighbor LEAF-IPV6 timers connect 10
 !
 neighbor ${PEER_IPV6} peer-group LEAF-IPV6
PEER_IPV6_EOF
fi

# 如果启用 EVPN，添加 RR 对等体
if [ "$EVPN_ENABLED" = "true" ]; then
    cat >> /etc/frr/frr.conf <<EVPN_PEER_EOF
 !
 ! iBGP to EVPN Route Reflector
 neighbor EVPN-RR peer-group
 neighbor EVPN-RR remote-as ${EVPN_RR_ASN}
 neighbor EVPN-RR description "EVPN-RR"
 neighbor EVPN-RR update-source ${LOCAL_IPV4}
 neighbor EVPN-RR send-community all
 neighbor EVPN-RR ebgp-multihop 10
 neighbor EVPN-RR bfd
 neighbor EVPN-RR timers 3 10
 neighbor EVPN-RR timers connect 10
 !
 neighbor ${EVPN_RR_IP} peer-group EVPN-RR
EVPN_PEER_EOF
fi

# 添加 IPv4 Unicast address-family
cat >> /etc/frr/frr.conf <<IPV4_AF_EOF
 !
 address-family ipv4 unicast
  network ${LOCAL_IPV4}/32
  neighbor LEAF-IPV4 activate
  neighbor LEAF-IPV4 next-hop-self
  neighbor LEAF-IPV4 soft-reconfiguration inbound
  maximum-paths 4
 exit-address-family
IPV4_AF_EOF

# 添加 IPv6 Unicast address-family（独立的 IPv6 会话）
if [ "${ENABLE_IPV6:-false}" = "true" ]; then
    cat >> /etc/frr/frr.conf <<IPV6_AF_EOF
 !
 address-family ipv6 unicast
  network ${LOCAL_IPV6}/128
  neighbor LEAF-IPV6 activate
  neighbor LEAF-IPV6 next-hop-self
  neighbor LEAF-IPV6 soft-reconfiguration inbound
  maximum-paths 4
 exit-address-family
IPV6_AF_EOF
fi

# 如果启用 EVPN，添加 L2VPN EVPN address-family
if [ "$EVPN_ENABLED" = "true" ]; then
    cat >> /etc/frr/frr.conf <<EVPN_AF_EOF
 !
 address-family l2vpn evpn
  neighbor EVPN-RR activate
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