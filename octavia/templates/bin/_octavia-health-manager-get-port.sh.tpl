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

# 获取当前节点名称
HOSTNAME=$(hostname -s)
PORTNAME=octavia-health-manager-port-$HOSTNAME

echo "当前节点: ${HOSTNAME}"
echo "端口名称: ${PORTNAME}"

# 获取端口的完整信息
if ! PORT_JSON=$(openstack port show ${PORTNAME} -f json 2>/dev/null); then
    echo "ERROR: 端口 ${PORTNAME} 不存在"
    echo "请先运行 Octavia 资源创建脚本"
    exit 1
fi

# 从JSON中提取所有需要的信息
PORT_ID=$(echo "$PORT_JSON" | grep '"id":' | cut -d'"' -f4)
PORT_MAC=$(echo "$PORT_JSON" | grep '"mac_address":' | cut -d'"' -f4)
PORT_IP=$(echo "$PORT_JSON" | grep '"ip_address":' | cut -d'"' -f4)
SUBNET_ID=$(echo "$PORT_JSON" | grep '"subnet_id":' | cut -d'"' -f4)
NETWORK_ID=$(echo "$PORT_JSON" | grep '"network_id":' | cut -d'"' -f4)

echo "端口 ID: ${PORT_ID}"
echo "端口 MAC: ${PORT_MAC}"
echo "端口 IP: ${PORT_IP}"
echo "子网 ID: ${SUBNET_ID}"
echo "网络 ID: ${NETWORK_ID}"

# 验证必需信息
if [ -z "${PORT_IP}" ] || [ -z "${SUBNET_ID}" ]; then
    echo "ERROR: 无法从端口信息中获取 IP 地址或子网 ID"
    exit 1
fi

# 获取子网的完整信息
SUBNET_JSON=$(openstack subnet show ${SUBNET_ID} -f json)

# 从子网JSON中提取有用信息
SUBNET_CIDR=$(echo "$SUBNET_JSON" | grep '"cidr":' | cut -d'"' -f4)
SUBNET_GATEWAY=$(echo "$SUBNET_JSON" | grep '"gateway_ip":' | cut -d'"' -f4)
SUBNET_NAME=$(echo "$SUBNET_JSON" | grep '"name":' | cut -d'"' -f4)

# 计算子网掩码
SUBNET_MASK=$(echo $SUBNET_CIDR | cut -d'/' -f2)
SUBNET_NETWORK=$(echo $SUBNET_CIDR | cut -d'/' -f1)

echo "子网名称: ${SUBNET_NAME}"
echo "子网 CIDR: ${SUBNET_CIDR}"
echo "子网网关: ${SUBNET_GATEWAY}"
echo "子网掩码: /${SUBNET_MASK}"

# 保存端口信息到共享目录
echo $PORT_ID > /tmp/pod-shared/HM_PORT_ID
echo $PORT_MAC > /tmp/pod-shared/HM_PORT_MAC
echo $PORT_IP > /tmp/pod-shared/HM_PORT_IP
echo $NETWORK_ID > /tmp/pod-shared/HM_NETWORK_ID

# 保存子网信息到共享目录
echo $SUBNET_ID > /tmp/pod-shared/HM_SUBNET_ID
echo $SUBNET_NAME > /tmp/pod-shared/HM_SUBNET_NAME
echo $SUBNET_CIDR > /tmp/pod-shared/HM_SUBNET_CIDR
echo $SUBNET_NETWORK > /tmp/pod-shared/HM_SUBNET_NETWORK
echo $SUBNET_MASK > /tmp/pod-shared/HM_SUBNET_MASK
echo $SUBNET_GATEWAY > /tmp/pod-shared/HM_SUBNET_GATEWAY

echo "完整的网络配置信息已保存到共享目录:"
echo "  端口: ${PORT_IP}/${SUBNET_MASK}"
echo "  网关: ${SUBNET_GATEWAY}"
echo "  子网: ${SUBNET_CIDR}"