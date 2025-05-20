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
  echo "  --cpu-arch ARCH           CPU架构 (默认: ${OSH_IRONIC_NODE_ARCH_DEFAULT})"
  echo "  --aggregate-name NAME     主机聚合名称 (默认: ${AGGREGATE_NAME_DEFAULT})"
  echo "  --compute-keyword KEYWORD 计算节点关键字 (默认: ${COMPUTE_KEYWORD_DEFAULT})"
  echo "  --help                    显示此帮助信息"
  echo ""
  echo "环境变量:"
  echo "  OS_CLOUD                  等同于 --os-cloud"
  echo "  OSH_IRONIC_NODE_ARCH      等同于 --cpu-arch"
  echo "  AGGREGATE_NAME            等同于 --aggregate-name"
  echo "  COMPUTE_KEYWORD           等同于 --compute-keyword"
}

# 设置默认值
OS_CLOUD_DEFAULT="openstack"
OSH_IRONIC_NODE_ARCH_DEFAULT="x86_64"
AGGREGATE_NAME_DEFAULT="baremetal-hosts"
COMPUTE_KEYWORD_DEFAULT="ironic"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --os-cloud)
      OS_CLOUD="$2"
      shift 2
      ;;
    --cpu-arch)
      OSH_IRONIC_NODE_ARCH="$2"
      shift 2
      ;;
    --aggregate-name)
      AGGREGATE_NAME="$2"
      shift 2
      ;;
    --compute-keyword)
      COMPUTE_KEYWORD="$2"
      shift 2
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
OSH_IRONIC_NODE_ARCH=${OSH_IRONIC_NODE_ARCH:-$OSH_IRONIC_NODE_ARCH_DEFAULT}
AGGREGATE_NAME=${AGGREGATE_NAME:-$AGGREGATE_NAME_DEFAULT}
COMPUTE_KEYWORD=${COMPUTE_KEYWORD:-$COMPUTE_KEYWORD_DEFAULT}

echo "使用以下参数:"
echo "OS_CLOUD = ${OS_CLOUD}"
echo "OSH_IRONIC_NODE_ARCH = ${OSH_IRONIC_NODE_ARCH}"
echo "AGGREGATE_NAME = ${AGGREGATE_NAME}"
echo "COMPUTE_KEYWORD = ${COMPUTE_KEYWORD}"

# 检查主机聚合是否已存在
AGGREGATE_EXISTS=$(openstack --os-cloud ${OS_CLOUD} aggregate list -f value -c Name | grep -c "${AGGREGATE_NAME}" || true)

if [ "$AGGREGATE_EXISTS" -eq "0" ]; then
  echo "创建裸金属主机聚合..."
  # 为裸金属节点创建主机聚合
  openstack --os-cloud ${OS_CLOUD} aggregate create \
    --property baremetal=true \
    --property cpu_arch=${OSH_IRONIC_NODE_ARCH} \
    ${AGGREGATE_NAME}
else
  echo "裸金属主机聚合已存在，跳过创建步骤"
fi

# 查找Ironic计算节点
echo "查找包含关键字 '${COMPUTE_KEYWORD}' 的计算节点..."
IRONIC_COMPUTES=$(openstack --os-cloud ${OS_CLOUD} compute service list | grep compute | grep -i "${COMPUTE_KEYWORD}" | grep -v down | awk '{print $4}')

# 如果没有找到Ironic计算节点，尝试使用nova-compute-ironic
if [ -z "$IRONIC_COMPUTES" ]; then
  echo "尝试查找包含 'nova-compute-ironic' 的计算节点..."
  IRONIC_COMPUTES=$(openstack --os-cloud ${OS_CLOUD} compute service list | grep compute | grep -i "nova-compute-ironic" | grep -v down | awk '{print $4}')
fi

# 如果仍未找到，提示用户
if [ -z "$IRONIC_COMPUTES" ]; then
  echo "警告: 未找到包含关键字 '${COMPUTE_KEYWORD}' 的计算节点。"
  echo "请手动添加计算节点到主机聚合:"
  echo "openstack --os-cloud ${OS_CLOUD} aggregate add host ${AGGREGATE_NAME} <计算节点名称>"
  exit 0
fi

# 将Ironic计算节点添加到主机聚合
for COMPUTE in $IRONIC_COMPUTES; do
  echo "检查计算节点 ${COMPUTE}..."
  # 检查计算节点是否已在聚合中
  IN_AGGREGATE=$(openstack --os-cloud ${OS_CLOUD} aggregate show ${AGGREGATE_NAME} -f value -c hosts | grep -c "$COMPUTE" || true)
  if [ "$IN_AGGREGATE" -eq "0" ]; then
    echo "将计算节点 ${COMPUTE} 添加到主机聚合 ${AGGREGATE_NAME}..."
    openstack --os-cloud ${OS_CLOUD} aggregate add host ${AGGREGATE_NAME} ${COMPUTE}
  else
    echo "计算节点 ${COMPUTE} 已在主机聚合中，跳过添加步骤"
  fi
done

echo "裸金属主机聚合配置完成。"