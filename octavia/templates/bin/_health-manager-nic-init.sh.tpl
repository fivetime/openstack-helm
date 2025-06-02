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

# ConfigMap 挂载路径
CONFIG_DIR="/etc/octavia/network-config"

# 读取网络配置函数
read_config() {
    local key=$1
    local default_value=$2
    if [ -f "${CONFIG_DIR}/${key}" ]; then
        cat "${CONFIG_DIR}/${key}"
    else
        echo "${default_value}"
    fi
}

# 从 ConfigMap 读取网络配置
NETWORK_NAME=$(read_config "network_name" "")
SUBNET_NAME=$(read_config "subnet_name" "")

echo "网络名称: ${NETWORK_NAME}"
echo "子网名称: ${SUBNET_NAME}"

# 验证必需的配置参数
if [ -z "${NETWORK_NAME}" ]; then
    echo "ERROR: network_name 参数不能为空"
    exit 1
fi

if [ -z "${SUBNET_NAME}" ]; then
    echo "ERROR: subnet_name 参数不能为空"
    exit 1
fi

# 获取网络和子网 ID
if ! NETWORK_ID=$(openstack network show ${NETWORK_NAME} -c id -f value 2>/dev/null); then
    echo "ERROR: 无法找到网络 '${NETWORK_NAME}'"
    exit 1
fi

if ! SUBNET_ID=$(openstack subnet show ${SUBNET_NAME} -c id -f value 2>/dev/null); then
    echo "ERROR: 无法找到子网 '${SUBNET_NAME}'"
    exit 1
fi

echo "网络 ID: ${NETWORK_ID}"
echo "子网 ID: ${SUBNET_ID}"

# 获取当前节点名称（与原始脚本保持一致）
HOSTNAME=$(hostname -s)
PORTNAME=octavia-health-manager-port-$HOSTNAME

echo "当前节点: ${HOSTNAME}"
echo "端口名称: ${PORTNAME}"

# 检查端口是否已存在
if openstack port show ${PORTNAME} &>/dev/null; then
    PORT_ID=$(openstack port show ${PORTNAME} -c id -f value)
else
    echo "创建端口 ${PORTNAME}"
    PORT_ID=$(openstack port create \
        --network ${NETWORK_ID} \
        --fixed-ip subnet=${SUBNET_ID} \
        --security-group lb-health-mgr-sec-grp \
        --device-owner compute:octavia \
        ${PORTNAME} \
        -c id -f value)
fi

# 获取端口详细信息
PORT_MAC=$(openstack port show ${PORTNAME} -c mac_address -f value)
# 使用 JSON 格式获取端口的固定IP信息
PORT_FIXED_IPS_JSON=$(openstack port show ${PORT_ID} -c fixed_ips -f json)
# 从指定子网中提取 IP 地址
PORT_IP=$(echo "${PORT_FIXED_IPS_JSON}" | grep -A 3 -B 1 "\"subnet_id\": \"${SUBNET_ID}\"" | grep "ip_address" | cut -d'"' -f4)

if [ -z "${PORT_IP}" ]; then
    echo "ERROR: 无法从指定子网获取 IP 地址"
    echo "指定的子网 ID: ${SUBNET_ID}"
    exit 1
fi

echo "从指定 ${SUBNET_ID} 子网获取的 IP 地址: ${PORT_IP}"

# 获取子网信息用于网络配置
SUBNET_CIDR=$(read_config "subnet_cidr" "")
SUBNET_MASK=$(echo $SUBNET_CIDR | cut -d'/' -f2)
SUBNET_GATEWAY=$(read_config "subnet_gateway" "")

# 将信息保存到共享目录
echo $PORT_ID > /tmp/pod-shared/HM_PORT_ID
echo $PORT_MAC > /tmp/pod-shared/HM_PORT_MAC
echo $PORT_IP > /tmp/pod-shared/HM_PORT_IP
echo $SUBNET_MASK > /tmp/pod-shared/HM_NETMASK
echo $SUBNET_GATEWAY > /tmp/pod-shared/HM_GATEWAY
echo $SUBNET_CIDR > /tmp/pod-shared/HM_SUBNET_CIDR