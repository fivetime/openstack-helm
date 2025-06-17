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

echo "=== Reading Network Configuration from ConfigMap ==="

# 从 ConfigMap 读取所有配置
NETWORK_TYPE=$(read_config "network_type" "flat")
DEVICE=$(read_config "device" "")
PROVIDER_NETWORK=$(read_config "provider_network" "")
NETWORK_NAME=$(read_config "network_name" "")
SUBNET_NAME=$(read_config "subnet_name" "")
SUBNET_CIDR=$(read_config "subnet_cidr" "")
SUBNET_ALLOC_START=$(read_config "subnet_alloc_start" "")
SUBNET_ALLOC_END=$(read_config "subnet_alloc_end" "")
SUBNET_GATEWAY=$(read_config "subnet_gateway" "")
SUBNET_DNS_SERVER=$(read_config "subnet_dns_server" "")
ENABLE_DHCP=$(read_config "enable_dhcp" "true")
SHARED=$(read_config "shared" "true")
MTU=$(read_config "mtu" "1500")
VLAN_ID=$(read_config "vlan_id" "")
SEGMENTATION_ID=$(read_config "segmentation_id" "")
SSH_KEY_NAME=$(read_config "ssh_key_name" "octavia_ssh_key")

# 验证必需的配置参数
echo "=== 验证必需的配置参数 ==="

if [ -z "${NETWORK_TYPE}" ]; then
    echo "ERROR: network_type 参数不能为空"
    exit 1
fi

if [ -z "${NETWORK_NAME}" ]; then
    echo "ERROR: network_name 参数不能为空"
    exit 1
fi

if [ -z "${SUBNET_NAME}" ]; then
    echo "ERROR: subnet_name 参数不能为空"
    exit 1
fi

if [ -z "${SUBNET_CIDR}" ]; then
    echo "ERROR: subnet_cidr 参数不能为空"
    exit 1
fi

if [ -z "${SUBNET_ALLOC_START}" ]; then
    echo "ERROR: subnet_alloc_start 参数不能为空"
    exit 1
fi

if [ -z "${SUBNET_ALLOC_END}" ]; then
    echo "ERROR: subnet_alloc_end 参数不能为空"
    exit 1
fi

# 根据网络类型验证特定参数
case ${NETWORK_TYPE} in
    flat|vlan)
        if [ -z "${PROVIDER_NETWORK}" ]; then
            echo "ERROR: ${NETWORK_TYPE} 网络类型需要设置 provider_network 参数"
            exit 1
        fi
        ;;
    vlan)
        if [ -z "${VLAN_ID}" ]; then
            echo "ERROR: vlan 网络类型需要设置 vlan_id 参数"
            exit 1
        fi
        ;;
    vxlan)
        # vxlan 类型的 segmentation_id 是可选的
        ;;
    *)
        echo "ERROR: 不支持的网络类型: ${NETWORK_TYPE} (支持: flat, vlan, vxlan)"
        exit 1
        ;;
esac

echo "Network Configuration:"
echo "  Type: ${NETWORK_TYPE}"
echo "  Device: ${DEVICE}"
echo "  Provider: ${PROVIDER_NETWORK}"
echo "  Name: ${NETWORK_NAME}"
echo "  Subnet: ${SUBNET_NAME} (${SUBNET_CIDR})"
echo "  Allocation Pool: ${SUBNET_ALLOC_START} - ${SUBNET_ALLOC_END}"
echo "  Gateway: ${SUBNET_GATEWAY}"
echo "  DNS Server: ${SUBNET_DNS_SERVER}"
echo "  MTU: ${MTU}"
echo "  Shared: ${SHARED}"
echo "  Enable DHCP: ${ENABLE_DHCP}"

echo "=== Creating/Updating Network Resources ==="

# 创建或获取网络
if ! openstack network show ${NETWORK_NAME} &>/dev/null; then
    echo "Creating network: ${NETWORK_NAME}"

    CREATE_CMD="openstack network create --mtu ${MTU}"

    # 根据 shared 参数决定是否共享网络
    if [ "${SHARED}" == "true" ]; then
        CREATE_CMD="${CREATE_CMD} --share"
    fi

    case ${NETWORK_TYPE} in
        flat)
            CREATE_CMD="${CREATE_CMD} --provider-network-type flat"
            if [ -n "${PROVIDER_NETWORK}" ]; then
                CREATE_CMD="${CREATE_CMD} --provider-physical-network ${PROVIDER_NETWORK}"
            fi
            ;;
        vlan)
            CREATE_CMD="${CREATE_CMD} --provider-network-type vlan"
            if [ -n "${PROVIDER_NETWORK}" ]; then
                CREATE_CMD="${CREATE_CMD} --provider-physical-network ${PROVIDER_NETWORK}"
            fi
            if [ -n "${VLAN_ID}" ]; then
                CREATE_CMD="${CREATE_CMD} --provider-segment ${VLAN_ID}"
            fi
            ;;
        vxlan)
            CREATE_CMD="${CREATE_CMD} --provider-network-type vxlan"
            if [ -n "${SEGMENTATION_ID}" ]; then
                CREATE_CMD="${CREATE_CMD} --provider-segment ${SEGMENTATION_ID}"
            fi
            ;;
        *)
            echo "ERROR: Unknown network type: ${NETWORK_TYPE}"
            exit 1
            ;;
    esac

    CREATE_CMD="${CREATE_CMD} ${NETWORK_NAME}"
    echo "Executing: ${CREATE_CMD}"
    NETWORK_ID=$(${CREATE_CMD} -f value -c id)
    echo "Created network: ${NETWORK_ID}"
else
    NETWORK_ID=$(openstack network show ${NETWORK_NAME} -f value -c id)
    echo "Network already exists: ${NETWORK_ID}"
fi

# 创建或获取子网
if ! openstack subnet list --network ${NETWORK_NAME} | grep -q ${SUBNET_NAME}; then
    echo "Creating subnet: ${SUBNET_NAME}"

    SUBNET_CMD="openstack subnet create"
    SUBNET_CMD="${SUBNET_CMD} --subnet-range ${SUBNET_CIDR}"
    SUBNET_CMD="${SUBNET_CMD} --allocation-pool start=${SUBNET_ALLOC_START},end=${SUBNET_ALLOC_END}"
    SUBNET_CMD="${SUBNET_CMD} --network ${NETWORK_NAME}"

    if [ "${ENABLE_DHCP}" == "true" ]; then
        SUBNET_CMD="${SUBNET_CMD} --dhcp"
    else
        SUBNET_CMD="${SUBNET_CMD} --no-dhcp"
    fi

    if [ -n "${SUBNET_GATEWAY}" ]; then
        SUBNET_CMD="${SUBNET_CMD} --gateway ${SUBNET_GATEWAY}"
    else
        SUBNET_CMD="${SUBNET_CMD} --no-gateway"
    fi

    if [ -n "${SUBNET_DNS_SERVER}" ]; then
        SUBNET_CMD="${SUBNET_CMD} --dns-nameserver ${SUBNET_DNS_SERVER}"
    fi

    SUBNET_CMD="${SUBNET_CMD} ${SUBNET_NAME}"
    echo "Executing: ${SUBNET_CMD}"
    SUBNET_ID=$(${SUBNET_CMD} -f value -c id)
    echo "Created subnet: ${SUBNET_ID}"
else
    SUBNET_ID=$(openstack subnet show ${SUBNET_NAME} -f value -c id)
    echo "Subnet already exists: ${SUBNET_ID}"
fi

# 创建管理安全组
if ! openstack security group show lb-mgmt-sec-grp &>/dev/null; then
    echo "Creating management security group..."
    SECGRP_ID=$(openstack security group create lb-mgmt-sec-grp -f value -c id)

    openstack security group rule create --protocol icmp ${SECGRP_ID}
    openstack security group rule create --protocol tcp --dst-port 22 ${SECGRP_ID}
    openstack security group rule create --protocol tcp --dst-port 9443 ${SECGRP_ID}

    if [ "${NETWORK_TYPE}" == "vxlan" ]; then
        openstack security group rule create --protocol udp --dst-port 4789 ${SECGRP_ID}
    fi

    echo "Created management security group: ${SECGRP_ID}"
else
    SECGRP_ID=$(openstack security group show lb-mgmt-sec-grp -f value -c id)
    echo "Management security group already exists: ${SECGRP_ID}"
fi

# 创建 Health Manager 安全组
if ! openstack security group show lb-health-mgr-sec-grp &>/dev/null; then
    echo "Creating health manager security group..."
    HM_SECGRP_ID=$(openstack security group create lb-health-mgr-sec-grp -f value -c id)
    openstack security group rule create --protocol udp --dst-port 5555 ${HM_SECGRP_ID}
    echo "Created health manager security group: ${HM_SECGRP_ID}"
else
    HM_SECGRP_ID=$(openstack security group show lb-health-mgr-sec-grp -f value -c id)
    echo "Health manager security group already exists: ${HM_SECGRP_ID}"
fi

# 处理 SSH 密钥
SSH_KEY_CREATED="false"
if ! openstack keypair show ${SSH_KEY_NAME} &>/dev/null; then
    echo "Creating SSH keypair..."

    if [ -f "/etc/octavia/ssh-key/public_key" ]; then
        PUBLIC_KEY_FILE="/tmp/octavia_ssh_key.pub"
        cp /etc/octavia/ssh-key/public_key ${PUBLIC_KEY_FILE}
        openstack keypair create --public-key ${PUBLIC_KEY_FILE} ${SSH_KEY_NAME}
        SSH_KEY_CREATED="true"
        echo "SSH keypair created: ${SSH_KEY_NAME}"
    else
        echo "WARNING: SSH public key not found. Skipping keypair creation."
    fi
else
    echo "SSH keypair already exists: ${SSH_KEY_NAME}"
fi

echo ""
echo "=============================================="
echo "=== NETWORK CONFIGURATION COMPLETED ==="
echo "=============================================="
echo "Network Type: ${NETWORK_TYPE}"
echo "Network Device: ${DEVICE}"
echo "Provider Network: ${PROVIDER_NETWORK}"
echo "Network ID: ${NETWORK_ID}"
echo "Subnet ID: ${SUBNET_ID}"
echo "Management Security Group ID: ${SECGRP_ID}"
echo "Health Manager Security Group ID: ${HM_SECGRP_ID}"
echo "SSH Keypair Created: ${SSH_KEY_CREATED}"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "These IDs can be used to configure Octavia services."
echo "=============================================="