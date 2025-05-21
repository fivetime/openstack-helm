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

# 显示脚本用法
function show_usage {
  echo "用法: $0 [options]"
  echo "选项:"
  echo "  --os-cloud CLOUD_NAME     OpenStack云环境名称 (默认: ${OS_CLOUD_DEFAULT})"
  echo "  --disk SIZE               磁盘大小(GB) (默认: ${OSH_IRONIC_NODE_DISC_DEFAULT})"
  echo "  --ram SIZE                内存大小(MB) (默认: ${OSH_IRONIC_NODE_RAM_DEFAULT})"
  echo "  --cpu COUNT               CPU数量 (默认: ${OSH_IRONIC_NODE_CPU_DEFAULT})"
  echo "  --cpu-arch ARCH           CPU架构 (默认: ${OSH_IRONIC_NODE_ARCH_DEFAULT})"
  echo "  --flavor-name NAME        Flavor名称 (默认: ${FLAVOR_NAME_DEFAULT})"
  echo "  --resource-class NAME     自定义资源类名称 (可选)"
  echo "  --update                  如果flavor已存在则更新 (默认: ${UPDATE_FLAVOR_DEFAULT})"
  echo "  --help                    显示此帮助信息"
  echo ""
  echo "环境变量:"
  echo "  OS_CLOUD                  等同于 --os-cloud"
  echo "  OSH_IRONIC_NODE_DISC      等同于 --disk"
  echo "  OSH_IRONIC_NODE_RAM       等同于 --ram"
  echo "  OSH_IRONIC_NODE_CPU       等同于 --cpu"
  echo "  OSH_IRONIC_NODE_ARCH      等同于 --cpu-arch"
  echo "  FLAVOR_NAME               等同于 --flavor-name"
  echo "  RESOURCE_CLASS            等同于 --resource-class"
  echo "  UPDATE_FLAVOR             等同于 --update"
}

# 设置默认值
OS_CLOUD_DEFAULT="openstack"
OSH_IRONIC_NODE_DISC_DEFAULT="20"
OSH_IRONIC_NODE_RAM_DEFAULT="4096"
OSH_IRONIC_NODE_CPU_DEFAULT="2"
OSH_IRONIC_NODE_ARCH_DEFAULT="x86_64"
FLAVOR_NAME_DEFAULT="baremetal"
UPDATE_FLAVOR_DEFAULT="false"
RESOURCE_CLASS=""

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
    --flavor-name)
      FLAVOR_NAME="$2"
      shift 2
      ;;
    --resource-class)
      RESOURCE_CLASS="$2"
      shift 2
      ;;
    --update)
      UPDATE_FLAVOR="true"
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
FLAVOR_NAME=${FLAVOR_NAME:-$FLAVOR_NAME_DEFAULT}
UPDATE_FLAVOR=${UPDATE_FLAVOR:-$UPDATE_FLAVOR_DEFAULT}
RESOURCE_CLASS=${RESOURCE_CLASS:-$RESOURCE_CLASS_ENV}

echo "使用以下参数:"
echo "OS_CLOUD = ${OS_CLOUD}"
echo "OSH_IRONIC_NODE_DISC = ${OSH_IRONIC_NODE_DISC}"
echo "OSH_IRONIC_NODE_RAM = ${OSH_IRONIC_NODE_RAM}"
echo "OSH_IRONIC_NODE_CPU = ${OSH_IRONIC_NODE_CPU}"
echo "OSH_IRONIC_NODE_ARCH = ${OSH_IRONIC_NODE_ARCH}"
echo "FLAVOR_NAME = ${FLAVOR_NAME}"
echo "UPDATE_FLAVOR = ${UPDATE_FLAVOR}"
if [ -n "${RESOURCE_CLASS}" ]; then
  echo "RESOURCE_CLASS = ${RESOURCE_CLASS}"
fi

# 检查flavor是否已存在
FLAVOR_EXISTS=$(openstack --os-cloud ${OS_CLOUD} flavor list -f value -c Name | grep -c "${FLAVOR_NAME}" || true)

# 构建flavor创建命令
CREATE_CMD="openstack --os-cloud ${OS_CLOUD} flavor create \
  --disk ${OSH_IRONIC_NODE_DISC} \
  --ram ${OSH_IRONIC_NODE_RAM} \
  --vcpus ${OSH_IRONIC_NODE_CPU} \
  --property cpu_arch=${OSH_IRONIC_NODE_ARCH} \
  --property baremetal=true"

# 如果指定了资源类，添加到创建命令
if [ -n "${RESOURCE_CLASS}" ]; then
  CREATE_CMD="${CREATE_CMD} \
  --property resources:${RESOURCE_CLASS}=1"
fi

# 添加flavor名称到创建命令
CREATE_CMD="${CREATE_CMD} ${FLAVOR_NAME}"

if [ "$FLAVOR_EXISTS" -eq "0" ]; then
  echo "创建裸金属flavor..."
  # 执行创建命令
  eval ${CREATE_CMD}
else
  echo "裸金属flavor已存在"

  # 如果指定了更新选项，则更新已存在的flavor
  if [ "${UPDATE_FLAVOR}" = "true" ]; then
    echo "更新已存在的裸金属flavor..."
    # 更新flavor基本属性
    openstack --os-cloud ${OS_CLOUD} flavor set ${FLAVOR_NAME} \
      --property cpu_arch=${OSH_IRONIC_NODE_ARCH} \
      --property baremetal=true

    # 获取当前flavor的所有属性
    FLAVOR_PROPS=$(openstack --os-cloud ${OS_CLOUD} flavor show ${FLAVOR_NAME} -f value -c properties)

    # 检查是否有任何resources属性
    RESOURCE_PROPS=$(echo ${FLAVOR_PROPS} | grep -o "resources:[^,]*" || echo "")

    # 如果有资源属性，先移除它们
    if [ -n "${RESOURCE_PROPS}" ]; then
      # 从字符串提取资源类型名称
      for RESOURCE_PROP in ${RESOURCE_PROPS}; do
        # 提取资源类型名称（格式：resources:RESOURCE_NAME=VALUE）
        RESOURCE_NAME=$(echo ${RESOURCE_PROP} | cut -d ":" -f 2 | cut -d "=" -f 1)
        echo "移除现有资源类型: resources:${RESOURCE_NAME}"
        openstack --os-cloud ${OS_CLOUD} flavor unset --property resources:${RESOURCE_NAME} ${FLAVOR_NAME}
      done
    fi

    # 如果指定了新的资源类，添加它
    if [ -n "${RESOURCE_CLASS}" ]; then
      echo "添加资源类型: resources:${RESOURCE_CLASS}"
      openstack --os-cloud ${OS_CLOUD} flavor set --property resources:${RESOURCE_CLASS}=1 ${FLAVOR_NAME}
    fi
  fi
fi

echo "当前可用flavor列表:"
openstack --os-cloud ${OS_CLOUD} flavor list | grep ${FLAVOR_NAME}
echo "Flavor详情:"
openstack --os-cloud ${OS_CLOUD} flavor show ${FLAVOR_NAME}