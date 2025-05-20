#!/bin/bash

#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

# 配置是否启用调试输出
SCRIPT_DEBUG=${SCRIPT_DEBUG:-false}
if [ "${SCRIPT_DEBUG}" = "true" ]; then
  set -x
else
  set -e
fi

# 根据OS_SYSTEM_SCOPE自动选择云环境
if [ "${OS_SYSTEM_SCOPE}" = "all" ] && [ -z "${OS_CLOUD}" ]; then
  echo "检测到系统范围认证请求，使用openstack_helm_system配置"
  OS_CLOUD_DEFAULT="openstack_helm_system"
else
  OS_CLOUD_DEFAULT="openstack_helm"
fi

# 显示脚本用法
function show_usage {
  echo "用法: $0 [options]"
  echo "选项:"
  echo "  --os-cloud CLOUD_NAME     OpenStack云环境名称 (默认: ${OS_CLOUD_DEFAULT})"
  echo "  --disk SIZE               磁盘大小(GB) (默认: ${OSH_IRONIC_NODE_DISC_DEFAULT})"
  echo "  --ram SIZE                内存大小(MB) (默认: ${OSH_IRONIC_NODE_RAM_DEFAULT})"
  echo "  --cpu COUNT               CPU数量 (默认: ${OSH_IRONIC_NODE_CPU_DEFAULT})"
  echo "  --cpu-arch ARCH           CPU架构 (默认: ${OSH_IRONIC_NODE_ARCH_DEFAULT})"
  echo "  --driver DRIVER           Ironic驱动 (默认: ${IRONIC_DRIVER_DEFAULT})"
  echo "  --deploy-kernel IMAGE     部署内核镜像名称 (默认: ${DEPLOY_KERNEL_NAME_DEFAULT})"
  echo "  --deploy-ramdisk IMAGE    部署ramdisk镜像名称 (默认: ${DEPLOY_RAMDISK_NAME_DEFAULT})"
  echo "  --nodes-file FILE         节点信息文件路径 (默认: ${NODES_FILE_DEFAULT})"
  echo "  --ipmi-port PORT          IPMI端口 (默认: ${IPMI_PORT_DEFAULT})"
  echo "  --ipmi-username USER      IPMI用户名 (默认: ${IPMI_USERNAME_DEFAULT})"
  echo "  --ipmi-password PASS      IPMI密码 (默认: ${IPMI_PASSWORD_DEFAULT})"
  echo "  --wait-timeout SECONDS    等待节点可用的超时时间 (默认: ${WAIT_TIMEOUT_DEFAULT})"
  echo "  --system-scope            使用系统范围认证 (默认: 否)"
  echo "  --help                    显示此帮助信息"
  echo ""
  echo "环境变量:"
  echo "  OS_CLOUD                  等同于 --os-cloud"
  echo "  OS_SYSTEM_SCOPE           如果设置为'all'，等同于 --system-scope"
  echo "  OSH_IRONIC_NODE_DISC      等同于 --disk"
  echo "  OSH_IRONIC_NODE_RAM       等同于 --ram"
  echo "  OSH_IRONIC_NODE_CPU       等同于 --cpu"
  echo "  OSH_IRONIC_NODE_ARCH      等同于 --cpu-arch"
  echo "  IRONIC_DRIVER             等同于 --driver"
  echo "  DEPLOY_KERNEL_NAME        等同于 --deploy-kernel"
  echo "  DEPLOY_RAMDISK_NAME       等同于 --deploy-ramdisk"
  echo "  NODES_FILE                等同于 --nodes-file"
  echo "  IPMI_PORT                 等同于 --ipmi-port"
  echo "  IPMI_USERNAME             等同于 --ipmi-username"
  echo "  IPMI_PASSWORD             等同于 --ipmi-password"
  echo "  WAIT_TIMEOUT              等同于 --wait-timeout"
}

# 设置默认值
OSH_IRONIC_NODE_DISC_DEFAULT="20"
OSH_IRONIC_NODE_RAM_DEFAULT="4096"
OSH_IRONIC_NODE_CPU_DEFAULT="2"
OSH_IRONIC_NODE_ARCH_DEFAULT="x86_64"
IRONIC_DRIVER_DEFAULT="ipmi"
DEPLOY_KERNEL_NAME_DEFAULT="ironic-agent.kernel"
DEPLOY_RAMDISK_NAME_DEFAULT="ironic-agent.initramfs"
NODES_FILE_DEFAULT="/tmp/bm-hosts.txt"
IPMI_PORT_DEFAULT="6230"
IPMI_USERNAME_DEFAULT="admin"
IPMI_PASSWORD_DEFAULT="password"
WAIT_TIMEOUT_DEFAULT="1200"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --os-cloud)
      OS_CLOUD="$2"
      shift 2
      ;;
    --disk)
      OSH_IRONIC_NODE_DISC="$2"
      shift 2
      ;;
    --ram)
      OSH_IRONIC_NODE_RAM="$2"
      shift 2
      ;;
    --cpu)
      OSH_IRONIC_NODE_CPU="$2"
      shift 2
      ;;
    --cpu-arch)
      OSH_IRONIC_NODE_ARCH="$2"
      shift 2
      ;;
    --driver)
      IRONIC_DRIVER="$2"
      shift 2
      ;;
    --deploy-kernel)
      DEPLOY_KERNEL_NAME="$2"
      shift 2
      ;;
    --deploy-ramdisk)
      DEPLOY_RAMDISK_NAME="$2"
      shift 2
      ;;
    --nodes-file)
      NODES_FILE="$2"
      shift 2
      ;;
    --ipmi-port)
      IPMI_PORT="$2"
      shift 2
      ;;
    --ipmi-username)
      IPMI_USERNAME="$2"
      shift 2
      ;;
    --ipmi-password)
      IPMI_PASSWORD="$2"
      shift 2
      ;;
    --wait-timeout)
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --system-scope)
      OS_SYSTEM_SCOPE="all"
      if [ -z "${OS_CLOUD}" ]; then
        OS_CLOUD="openstack_helm_system"
      fi
      shift
      ;;
    --help)
      show_usage
      exit 0
      ;;
    *)
      echo "未知选项: $1"
      show_usage
      exit 1
      ;;
  esac
done

# 应用环境变量或默认值
OS_CLOUD=${OS_CLOUD:-$OS_CLOUD_DEFAULT}
OSH_IRONIC_NODE_DISC=${OSH_IRONIC_NODE_DISC:-$OSH_IRONIC_NODE_DISC_DEFAULT}
OSH_IRONIC_NODE_RAM=${OSH_IRONIC_NODE_RAM:-$OSH_IRONIC_NODE_RAM_DEFAULT}
OSH_IRONIC_NODE_CPU=${OSH_IRONIC_NODE_CPU:-$OSH_IRONIC_NODE_CPU_DEFAULT}
OSH_IRONIC_NODE_ARCH=${OSH_IRONIC_NODE_ARCH:-$OSH_IRONIC_NODE_ARCH_DEFAULT}
IRONIC_DRIVER=${IRONIC_DRIVER:-$IRONIC_DRIVER_DEFAULT}
DEPLOY_KERNEL_NAME=${DEPLOY_KERNEL_NAME:-$DEPLOY_KERNEL_NAME_DEFAULT}
DEPLOY_RAMDISK_NAME=${DEPLOY_RAMDISK_NAME:-$DEPLOY_RAMDISK_NAME_DEFAULT}
NODES_FILE=${NODES_FILE:-$NODES_FILE_DEFAULT}
IPMI_PORT=${IPMI_PORT:-$IPMI_PORT_DEFAULT}
IPMI_USERNAME=${IPMI_USERNAME:-$IPMI_USERNAME_DEFAULT}
IPMI_PASSWORD=${IPMI_PASSWORD:-$IPMI_PASSWORD_DEFAULT}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-$WAIT_TIMEOUT_DEFAULT}

echo "使用以下参数:"
echo "OS_CLOUD = ${OS_CLOUD}"
echo "OSH_IRONIC_NODE_DISC = ${OSH_IRONIC_NODE_DISC}"
echo "OSH_IRONIC_NODE_RAM = ${OSH_IRONIC_NODE_RAM}"
echo "OSH_IRONIC_NODE_CPU = ${OSH_IRONIC_NODE_CPU}"
echo "OSH_IRONIC_NODE_ARCH = ${OSH_IRONIC_NODE_ARCH}"
echo "IRONIC_DRIVER = ${IRONIC_DRIVER}"
echo "DEPLOY_KERNEL_NAME = ${DEPLOY_KERNEL_NAME}"
echo "DEPLOY_RAMDISK_NAME = ${DEPLOY_RAMDISK_NAME}"
echo "NODES_FILE = ${NODES_FILE}"
echo "IPMI_PORT = ${IPMI_PORT}"
echo "IPMI_USERNAME = ${IPMI_USERNAME}"
echo "IPMI_PASSWORD = ******** (隐藏)"
echo "WAIT_TIMEOUT = ${WAIT_TIMEOUT}"
if [ "${OS_SYSTEM_SCOPE}" = "all" ]; then
  echo "使用系统范围认证"
fi

# 检查节点信息文件是否存在
if [ ! -f "${NODES_FILE}" ]; then
  echo "错误: 未找到节点信息文件 ${NODES_FILE}"
  echo "请创建包含节点信息的文件，格式为: BMC_IP MAC_ADDRESS"
  exit 1
fi

# 检查部署镜像是否存在
echo "检查部署镜像..."
if ! openstack --os-cloud ${OS_CLOUD} image show ${DEPLOY_KERNEL_NAME} &>/dev/null; then
  echo "错误: 未找到部署内核镜像 ${DEPLOY_KERNEL_NAME}"
  echo "请先上传部署镜像或指定正确的镜像名称"
  exit 1
fi

if ! openstack --os-cloud ${OS_CLOUD} image show ${DEPLOY_RAMDISK_NAME} &>/dev/null; then
  echo "错误: 未找到部署ramdisk镜像 ${DEPLOY_RAMDISK_NAME}"
  echo "请先上传部署镜像或指定正确的镜像名称"
  exit 1
fi

# 获取部署镜像UUID
DEPLOY_VMLINUZ_UUID=$(openstack --os-cloud ${OS_CLOUD} image show ${DEPLOY_KERNEL_NAME} -f value -c id)
DEPLOY_INITRD_UUID=$(openstack --os-cloud ${OS_CLOUD} image show ${DEPLOY_RAMDISK_NAME} -f value -c id)

# 等待节点变为可用的函数
function wait_for_ironic_node {
  set +x
  local node=$1
  local timeout=${2:-$WAIT_TIMEOUT}
  local end=$(($(date +%s) + timeout))
  
  while true; do
    local state=$(openstack --os-cloud ${OS_CLOUD} baremetal node show $node -f value -c provision_state)
    if [ "x${state}" == "xavailable" ]; then
      echo "节点 $node 现在处于available状态"
      break
    fi
    sleep 10
    local now=$(date +%s)
    if [ $now -gt $end ]; then
      echo "错误：节点 $node 在 $timeout 秒内未变为available状态"
      openstack --os-cloud ${OS_CLOUD} baremetal node show $node
      return 1
    fi
    echo "等待节点 $node 变为available状态，当前状态: $state"
  done
  set -x
  return 0
}

# 等待节点进入特定状态的函数
function wait_for_node_state {
  local node=$1
  local target_state=$2
  local timeout=300  # 5分钟超时
  local end=$(($(date +%s) + timeout))
  
  while true; do
    local state=$(openstack --os-cloud ${OS_CLOUD} baremetal node show ${node} -f value -c provision_state)
    if [ "x${state}" == "x${target_state}" ]; then
      echo "节点 ${node} 已进入 ${target_state} 状态"
      break
    fi
    sleep 5
    local now=$(date +%s)
    if [ $now -gt $end ]; then
      echo "错误：节点 ${node} 未能在 ${timeout} 秒内进入 ${target_state} 状态"
      return 1
    fi
    echo "等待节点 ${node} 进入 ${target_state} 状态，当前状态: ${state}"
  done
  return 0
}

# 检查节点是否存在于Ironic中
function node_exists_by_mac {
  local mac=$1
  local node_uuid=""
  
  # 通过MAC地址查找端口
  local port_uuid=$(openstack --os-cloud ${OS_CLOUD} baremetal port list --address "${mac}" -f value -c UUID 2>/dev/null || echo "")
  
  # 如果找到端口，获取关联的节点UUID
  if [ -n "$port_uuid" ]; then
    node_uuid=$(openstack --os-cloud ${OS_CLOUD} baremetal port show "${port_uuid}" -f value -c node_uuid)
  fi
  
  echo ${node_uuid}
}

echo "开始注册裸金属节点..."

# 读取节点信息文件并处理每个节点
while read NODE_DETAIL_RAW; do
  # 跳过空行和注释行
  if [[ -z "${NODE_DETAIL_RAW}" || "${NODE_DETAIL_RAW}" =~ ^# ]]; then
    continue
  fi
  
  NODE_DETAIL=($NODE_DETAIL_RAW)
  NODE_BMC_IP=${NODE_DETAIL[0]}
  NODE_MAC=${NODE_DETAIL[1]}
  
  echo "处理节点: BMC IP=${NODE_BMC_IP}, MAC=${NODE_MAC}"
  
  # 检查MAC地址是否已注册
  BM_NODE=$(node_exists_by_mac "${NODE_MAC}")
  
  if [ -n "$BM_NODE" ]; then
    echo "找到已存在的节点 UUID: ${BM_NODE}，MAC地址: ${NODE_MAC}"
  else
    # 直接获取现有节点列表
    EXISTING_NODES=$(openstack --os-cloud ${OS_CLOUD} baremetal node list -f value -c UUID -c Name)
    echo "当前存在的节点:"
    echo "$EXISTING_NODES"
    
    # 使用循环手动处理而不是直接创建节点
    echo "正在尝试查找或创建合适的节点..."
    
    # 检查是否存在与此节点对应的节点（通过IPMI地址判断）
    NODE_BY_IPMI=$(openstack --os-cloud ${OS_CLOUD} baremetal node list --driver-info ipmi_address=${NODE_BMC_IP} -f value -c UUID 2>/dev/null || echo "")
    
    if [ -n "$NODE_BY_IPMI" ]; then
      echo "找到通过IPMI地址匹配的节点，UUID: ${NODE_BY_IPMI}"
      BM_NODE=$NODE_BY_IPMI
      
      # 检查该节点是否已有该MAC地址的端口
      PORT_EXISTS=$(openstack --os-cloud ${OS_CLOUD} baremetal port list --node ${BM_NODE} --address ${NODE_MAC} -f value -c UUID 2>/dev/null || echo "")
      
      if [ -z "$PORT_EXISTS" ]; then
        echo "为节点 ${BM_NODE} 添加MAC地址 ${NODE_MAC} 的端口..."
        openstack --os-cloud ${OS_CLOUD} baremetal port create --node ${BM_NODE} "${NODE_MAC}"
      else
        echo "节点 ${BM_NODE} 已有MAC地址为 ${NODE_MAC} 的端口"
      fi
    else
      # 如果没有找到匹配的节点，则创建新节点
      echo "创建新节点..."
      
      # 获取所有已存在的节点名称
      EXISTING_NODE_NAMES=$(openstack --os-cloud ${OS_CLOUD} baremetal node list -f value -c Name)
      
      # 清理MAC地址和BMC IP以用于节点名称
      MAC_CLEAN=$(echo ${NODE_MAC} | tr ':' '-')
      BMC_IP_CLEAN=$(echo ${NODE_BMC_IP} | tr '.' '-')
      
      # 生成基本节点名称
      BASE_NODE_NAME="baremetal-${BMC_IP_CLEAN}-${MAC_CLEAN}"
      
      # 检查节点名称是否已存在
      if echo "$EXISTING_NODE_NAMES" | grep -q "^${BASE_NODE_NAME}$"; then
        echo "节点名称 ${BASE_NODE_NAME} 已存在，但MAC地址不同"
        # 生成一个带有随机后缀的唯一名称（只在必要时使用）
        RANDOM_SUFFIX=$(date +%s%N | sha256sum | head -c 8)
        NODE_NAME="${BASE_NODE_NAME}-${RANDOM_SUFFIX}"
        echo "使用新节点名称: ${NODE_NAME}"
      else
        NODE_NAME="${BASE_NODE_NAME}"
      fi
      
      # 创建节点
      BM_NODE=$(openstack --os-cloud ${OS_CLOUD} baremetal node create \
                --driver ${IRONIC_DRIVER} \
                --driver-info ipmi_username=${IPMI_USERNAME} \
                --driver-info ipmi_password=${IPMI_PASSWORD} \
                --driver-info ipmi_address="${NODE_BMC_IP}" \
                --driver-info ipmi_port=${IPMI_PORT} \
                --driver-info deploy_kernel=${DEPLOY_VMLINUZ_UUID} \
                --driver-info deploy_ramdisk=${DEPLOY_INITRD_UUID} \
                --property local_gb=${OSH_IRONIC_NODE_DISC} \
                --property memory_mb=${OSH_IRONIC_NODE_RAM} \
                --property cpus=${OSH_IRONIC_NODE_CPU} \
                --property cpu_arch=${OSH_IRONIC_NODE_ARCH} \
                --name "${NODE_NAME}" \
                -f value -c uuid)
      
      if [ -z "$BM_NODE" ]; then
        echo "无法创建节点，跳过此节点"
        continue
      fi
      
      echo "创建节点端口..."
      openstack --os-cloud ${OS_CLOUD} baremetal port create --node ${BM_NODE} "${NODE_MAC}"
    fi
  fi
  
  # 获取当前节点状态
  NODE_STATE=$(openstack --os-cloud ${OS_CLOUD} baremetal node show ${BM_NODE} -f value -c provision_state)
  
  # 根据当前状态执行下一步操作
  case $NODE_STATE in
    manageable)
      echo "节点已处于manageable状态，进行验证和提供流程..."
      ;;
    available)
      echo "节点已处于available状态，跳过管理流程..."
      openstack --os-cloud ${OS_CLOUD} baremetal node show ${BM_NODE}
      continue
      ;;
    *)
      echo "将节点转换为manageable状态..."
      openstack --os-cloud ${OS_CLOUD} baremetal node manage ${BM_NODE}
      
      # 等待节点进入manageable状态
      echo "等待节点进入manageable状态..."
      wait_for_node_state ${BM_NODE} "manageable"
      ;;
  esac
  
  echo "验证节点配置..."
  openstack --os-cloud ${OS_CLOUD} baremetal node validate ${BM_NODE}
  
  echo "将节点转换为available状态..."
  openstack --os-cloud ${OS_CLOUD} baremetal node provide ${BM_NODE}

done < "${NODES_FILE}"

echo "等待所有节点变为可用状态..."
for NODE in $(openstack --os-cloud ${OS_CLOUD} baremetal node list -f value -c UUID); do
  wait_for_ironic_node ${NODE}
done

echo "所有裸金属节点注册完成并可用:"
openstack --os-cloud ${OS_CLOUD} baremetal node list