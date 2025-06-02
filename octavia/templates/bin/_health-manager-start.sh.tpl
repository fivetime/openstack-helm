#!/bin/bash

{{/*
Copyright 2019 Samsung Electronics Co., Ltd.

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
COMMAND="${@:-start}"

function start () {
  echo "=== 配置 Health Manager 网络接口 ==="

  # 从共享目录读取端口信息
  if [ -f "/tmp/pod-shared/HM_PORT_IP" ]; then
    HM_PORT_IP=$(cat /tmp/pod-shared/HM_PORT_IP)
    HM_NETMASK=$(cat /tmp/pod-shared/HM_NETMASK)
    HM_GATEWAY=$(cat /tmp/pod-shared/HM_GATEWAY)
    HM_SUBNET_CIDR=$(cat /tmp/pod-shared/HM_SUBNET_CIDR)

    echo "配置静态 IP 地址: ${HM_PORT_IP}/${HM_NETMASK}"
    echo "网关: ${HM_GATEWAY}"
    echo "子网: ${HM_SUBNET_CIDR}"

    # 静态配置网络接口
    ip addr add ${HM_PORT_IP}/${HM_NETMASK} dev o-hm0
    ip link set o-hm0 up

    # 添加路由（如果需要）
    if [ -n "$HM_GATEWAY" ] && [ "$HM_GATEWAY" != "null" ]; then
      ip route add ${HM_SUBNET_CIDR} via ${HM_GATEWAY} dev o-hm0 || true
    fi

    echo "网络接口配置完成:"
    ip addr show o-hm0
    echo ""

  else
    echo "警告: 未找到端口 IP 信息，尝试启用接口但不配置 IP"
    ip link set o-hm0 up || true
  fi

  echo "=== 启动 Octavia Health Manager 服务 ==="
  exec octavia-health-manager \
        --config-file /etc/octavia/octavia.conf
}

function stop () {
  kill -TERM 1
}

$COMMAND