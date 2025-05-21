#!/bin/bash

# 示例：如何使用改进的参数化脚本

# 设置基本环境变量
export OS_CLOUD="openstack"
export OSH_IRONIC_NODE_DISC="20"
export OSH_IRONIC_NODE_RAM="4096" 
export OSH_IRONIC_NODE_CPU="2"
export OSH_IRONIC_NODE_ARCH="x86_64"

echo "============= 方法1: 使用环境变量 ============="
echo "使用已设置的环境变量运行脚本..."

# 运行脚本，使用环境变量（不指定资源类）
./800-create-baremetal-host-aggregate.sh
./810-register-baremetal-nodes.sh
./820-create-baremetal-flavor.sh

echo ""
echo "============= 方法2: 使用命令行参数 ============="
echo "使用命令行参数运行脚本..."

# 运行脚本，使用命令行参数
./800-create-baremetal-host-aggregate.sh \
  --os-cloud openstack \
  --cpu-arch x86_64 \
  --aggregate-name custom-baremetal-hosts

./810-register-baremetal-nodes.sh \
  --os-cloud openstack \
  --disk 40 \
  --ram 8192 \
  --cpu 4 \
  --cpu-arch x86_64 \
  --nodes-file /tmp/custom-nodes.txt \
  --ipmi-username myuser \
  --ipmi-password mysecret

./820-create-baremetal-flavor.sh \
  --os-cloud openstack \
  --disk 40 \
  --ram 8192 \
  --cpu 4 \
  --flavor-name baremetal-large \
  --update

echo ""
echo "============= 方法3: 使用资源类型 ============="
echo "创建带有资源类型的裸金属Flavor..."

# 为不同类型的裸金属节点创建对应的Flavor
./820-create-baremetal-flavor.sh \
  --os-cloud openstack \
  --disk 80 \
  --ram 16384 \
  --cpu 8 \
  --flavor-name baremetal-compute \
  --resource-class CUSTOM_BAREMETAL_COMPUTE

./820-create-baremetal-flavor.sh \
  --os-cloud openstack \
  --disk 200 \
  --ram 8192 \
  --cpu 4 \
  --flavor-name baremetal-storage \
  --resource-class CUSTOM_BAREMETAL_STORAGE

# 也可以使用环境变量设置资源类型
export RESOURCE_CLASS="CUSTOM_BAREMETAL_MEMORY"
./820-create-baremetal-flavor.sh \
  --flavor-name baremetal-memory \
  --disk 40 \
  --ram 32768 \
  --cpu 4

echo ""
echo "============= 脚本帮助信息 ============="
echo "获取脚本帮助信息..."

# 显示帮助信息
./800-create-baremetal-host-aggregate.sh --help
./810-register-baremetal-nodes.sh --help
./820-create-baremetal-flavor.sh --help