#!/bin/bash

{{/*
管理网端口(照 octavia 的 health-manager-get-port 改):每个网络节点一个
raas-orchestrator-port-<节点名>,nic-init 把它插进 br-int,编排器 / gitlab-runner
的 hostNetwork pod 从它进管理网(ci-mgmt-net)。

⚠️ Neutron API 里这个口**永远显示 unbound/DOWN** —— Octavia 的 o-hm0 一样。
判据看 ovn-controller 日志里的 "Claiming ... Setting lport up",
不要看 openstack port show。
*/}}

set -ex

HOSTNAME=$(hostname -s)
PORTNAME=raas-orchestrator-port-$HOSTNAME
NETWORK="{{ .Values.network.mgmt.network }}"
# 同一节点上可能有两个 pod 跑这份脚本(编排器 + gitlab-runner)。只让一个建
# (RAAS_MGMT_CREATE_PORT=false 的只等):并发 create 会造出两个同名端口。
CREATE="${RAAS_MGMT_CREATE_PORT:-true}"
# openstack CLI 要写 ~/.cache;容器以非 root 跑,家目录未必可写。
export HOME=/tmp

show_port() { openstack port show "$PORTNAME" -f json 2>/dev/null; }

PORT_JSON=$(show_port || true)
if [ -z "$PORT_JSON" ] && [ "$CREATE" = "true" ]; then
    # 端口不带安全组(disable-port-security):这是**我们自己**这一端的口,
    # 入向没有任何人会主动连;省掉一份要跟着管理网走的 SG 维护。
    openstack port create --network "$NETWORK" --disable-port-security "$PORTNAME" || true
fi
for i in $(seq 1 60); do
    PORT_JSON=$(show_port || true)
    [ -n "$PORT_JSON" ] && break
    echo "等待端口 $PORTNAME(由编排器 pod 创建)..."
    sleep 5
done
if [ -z "$PORT_JSON" ]; then
    echo "ERROR: 端口 $PORTNAME 始终不存在"
    exit 1
fi

# 用 JSON 解析器取字段,不用 grep/cut:开了 DNS 扩展的端口 ip_address 会出现
# 两次(fixed_ips 与 dns_assignment),grep 拿到的是两个值拼一起。
eval "$(echo "$PORT_JSON" | python3 -c '
import json, sys
p = json.load(sys.stdin)
fixed = (p.get("fixed_ips") or [{}])[0]
print("PORT_ID=%s" % p.get("id", ""))
print("PORT_MAC=%s" % p.get("mac_address", ""))
print("PORT_IP=%s" % fixed.get("ip_address", ""))
print("SUBNET_ID=%s" % fixed.get("subnet_id", ""))
')"

if [ -z "$PORT_IP" ] || [ -z "$SUBNET_ID" ]; then
    echo "ERROR: 端口没有地址或子网"
    exit 1
fi

SUBNET_CIDR=$(openstack subnet show "$SUBNET_ID" -f value -c cidr)
SUBNET_MASK=${SUBNET_CIDR##*/}

mkdir -p /tmp/pod-shared
echo "$PORT_ID"     > /tmp/pod-shared/MGMT_PORT_ID
echo "$PORT_MAC"    > /tmp/pod-shared/MGMT_PORT_MAC
echo "$PORT_IP"     > /tmp/pod-shared/MGMT_PORT_IP
echo "$SUBNET_MASK" > /tmp/pod-shared/MGMT_SUBNET_MASK

echo "管理网端口就绪: $PORT_IP/$SUBNET_MASK ($PORT_ID)"
