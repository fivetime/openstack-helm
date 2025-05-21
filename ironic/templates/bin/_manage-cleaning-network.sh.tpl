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

# 设置默认为flat网络，无VLAN
NETWORK_TYPE=${neutron_network_type:-flat}
VLAN_ID=${neutron_vlan_id:-}

# 构建网络创建命令
CREATE_NETWORK_CMD="openstack network create -f value -c id \
  --share --provider-network-type ${NETWORK_TYPE} \
  --provider-physical-network ${neutron_provider_network}"

# 如果是vlan类型，添加vlan id参数
if [ "${NETWORK_TYPE}" == "vlan" ] && [ -n "${VLAN_ID}" ]; then
  CREATE_NETWORK_CMD="${CREATE_NETWORK_CMD} --provider-segment ${VLAN_ID}"
elif [ "${NETWORK_TYPE}" == "vlan" ] && [ -z "${VLAN_ID}" ]; then
  echo "Error: VLAN ID is required for vlan network type"
  exit 1
fi

# 添加网络名称
CREATE_NETWORK_CMD="${CREATE_NETWORK_CMD} ${neutron_network_name}"

# 检查网络是否存在，如果不存在则创建
if ! openstack network show ${neutron_network_name}; then
  echo "Creating ${NETWORK_TYPE} network ${neutron_network_name}..."

  # 执行创建命令并捕获输出
  IRONIC_NEUTRON_CLEANING_NET_ID=$(eval "${CREATE_NETWORK_CMD}" || echo "")

  # 检查创建是否成功
  if [ -z "${IRONIC_NEUTRON_CLEANING_NET_ID}" ]; then
    echo "Failed to create network. Checking for alternatives..."

    # 尝试获取现有网络列表
    AVAILABLE_NETWORKS=$(openstack network list -f value -c ID -c Name)
    if [ -n "${AVAILABLE_NETWORKS}" ]; then
      echo "Available networks:"
      echo "${AVAILABLE_NETWORKS}"
      echo "Please specify one of these networks in your configuration."
    fi

    echo "Error: Network creation failed and no suitable alternative found."
    exit 1
  fi
else
  IRONIC_NEUTRON_CLEANING_NET_ID=$(openstack network show ${neutron_network_name} -f value -c id)
fi

# 确保网络ID已获取
if [ -z "${IRONIC_NEUTRON_CLEANING_NET_ID}" ]; then
  echo "Error: Failed to get network ID"
  exit 1
fi

# 检查并创建子网
SUBNET_OUTPUT=$(openstack network show $IRONIC_NEUTRON_CLEANING_NET_ID -f yaml)
SUBNET_EXISTS=false

# 提取子网ID列表
SUBNET_IDS=$(echo "$SUBNET_OUTPUT" | grep -A10 "subnets:" | grep -e "- " | sed 's/^[^a-zA-Z0-9]*- //g')

if [ -n "$SUBNET_IDS" ]; then
  for SUBNET_ID in $SUBNET_IDS; do
    CURRENT_SUBNET=$(openstack subnet show $SUBNET_ID -f value -c name)
    if [ "x${CURRENT_SUBNET}" == "x${neutron_subnet_name}" ]; then
      openstack subnet show ${neutron_subnet_name}
      SUBNET_EXISTS=true
      break
    fi
  done
fi

if [ "x${SUBNET_EXISTS}" != "xtrue" ]; then
  echo "Creating subnet ${neutron_subnet_name}..."
  openstack subnet create \
    --gateway ${neutron_subnet_gateway%/*} \
    --allocation-pool start=${neutron_subnet_alloc_start},end=${neutron_subnet_alloc_end} \
    --dns-nameserver ${neutron_subnet_dns_nameserver} \
    --subnet-range ${neutron_subnet_cidr} \
    --network ${neutron_network_name} \
    ${neutron_subnet_name}
fi

echo "Network and subnet setup completed successfully."