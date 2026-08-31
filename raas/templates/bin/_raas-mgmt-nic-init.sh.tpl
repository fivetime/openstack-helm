#!/bin/bash

{{/*
把管理网端口插进 br-int(照 octavia 的 health-manager-nic-init 改)。
OVS internal 口 + external-ids:iface-id → ovn-controller 认领这个 lport,
之后节点上的 hostNetwork 进程就能直接走管理网。

幂等:--may-exist / ip addr replace,pod 重启不会翻车。
skip_cleanup=true 让 ovs 清理脚本别动它 —— 口是节点级资源,pod 没了它还要在。
*/}}

set -ex

MGMT_PORT_ID=$(cat /tmp/pod-shared/MGMT_PORT_ID)
MGMT_PORT_MAC=$(cat /tmp/pod-shared/MGMT_PORT_MAC)
MGMT_PORT_IP=$(cat /tmp/pod-shared/MGMT_PORT_IP)
MGMT_SUBNET_MASK=$(cat /tmp/pod-shared/MGMT_SUBNET_MASK)
IFACE="{{ .Values.network.mgmt.interface }}"
MTU="{{ .Values.network.mgmt.mtu }}"

ovs-vsctl --no-wait show

ovs-vsctl --may-exist add-port br-int "$IFACE" \
        -- set Interface "$IFACE" type=internal \
        -- set Interface "$IFACE" external-ids:iface-status=active \
        -- set Interface "$IFACE" external-ids:attached-mac="$MGMT_PORT_MAC" \
        -- set Interface "$IFACE" external-ids:iface-id="$MGMT_PORT_ID" \
        -- set Interface "$IFACE" external-ids:skip_cleanup=true \
        -- set Interface "$IFACE" mtu_request="$MTU"

ip link set dev "$IFACE" address "$MGMT_PORT_MAC"
ip link set dev "$IFACE" mtu "$MTU"
# 管理子网无网关(不通公网是设计),静态配地址即可;
# 前缀长度自带链路内路由,机器侧的 /108 都在这条路由里。
ip addr replace "$MGMT_PORT_IP/$MGMT_SUBNET_MASK" dev "$IFACE"
ip link set dev "$IFACE" up

ip -6 addr show dev "$IFACE" || ip addr show dev "$IFACE"
