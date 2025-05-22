# Kuryr-libnetwork SR-IOV 支持配置

## SR-IOV 功能概述

SR-IOV (Single Root I/O Virtualization) 允许单个物理网卡虚拟化为多个虚拟网卡，提供：
- 低延迟网络访问
- 接近线速的网络性能
- 硬件级别的网络隔离

## 配置架构说明

SR-IOV 支持需要在多个组件中配置：

### 1. **Neutron 端配置（必需）**
在 OpenStack Neutron 服务中配置：

```ini
# /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
mechanism_drivers = openvswitch,sriovnicswitch

[ml2_sriov]
supported_pci_vendor_devs = 8086:10ed,8086:1515
agent_required = True

# /etc/neutron/plugins/ml2/sriov_agent.ini  
[sriov_nic]
physical_device_mappings = physnet1:ens1f0,physnet2:ens1f1
exclude_devices = 
```

### 2. **Kuryr-libnetwork 端配置**

```yaml
network:
  kuryr:
    sriov:
      enabled: true
      supported_vnic_types: "normal,direct,direct-physical,macvtap"

conf:
  kuryr:
    DEFAULT:
      # Kuryr 会自动启用 sriov 驱动
      enabled_port_drivers: 
        - kuryr_libnetwork.port_driver.drivers.veth
        - kuryr_libnetwork.port_driver.drivers.sriov
    binding:
      enabled_drivers:
        - kuryr.lib.binding.drivers.veth
        - kuryr.lib.binding.drivers.hw_veb
```

## 启用SR-IOV支持

### 1. 修改values.yaml配置

```yaml
network:
  kuryr:
    sriov:
      enabled: true  # 🔧 启用SR-IOV支持
```

### 2. 前置条件

#### 2.1 硬件要求
- 支持SR-IOV的网卡（Intel 82599, X710等）
- BIOS中启用VT-d/IOMMU
- CPU支持虚拟化扩展

#### 2.2 内核配置
```bash
# 启用IOMMU
# 在GRUB配置中添加：
intel_iommu=on iommu=pt

# 加载SR-IOV模块
modprobe vfio-pci
```

#### 2.3 创建虚拟功能(VF)
```bash
# 查看SR-IOV设备
lspci | grep Ethernet

# 启用VF（例如创建8个VF）
echo 8 > /sys/class/net/ens1f0/device/sriov_numvfs

# 验证VF创建
lspci | grep "Virtual Function"
```

### 3. OpenStack Neutron配置

#### 3.1 启用SR-IOV Mechanism Driver
在 Neutron controller 节点：
```ini
# /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
mechanism_drivers = openvswitch,sriovnicswitch

[ml2_sriov]
supported_pci_vendor_devs = 8086:10ed,8086:1515
agent_required = True
```

#### 3.2 部署SR-IOV Agent
在计算节点部署 `neutron-sriov-agent`：
```ini
# /etc/neutron/plugins/ml2/sriov_agent.ini
[sriov_nic]
physical_device_mappings = physnet1:ens1f0,physnet2:ens1f1
exclude_devices = 
```

## 使用SR-IOV

### 1. 创建SR-IOV网络
```bash
# 创建物理网络
openstack network create --provider-physical-network physnet1 \
  --provider-network-type vlan --provider-segment 100 sriov-net

# 创建子网
openstack subnet create --network sriov-net --subnet-range 192.168.100.0/24 \
  --gateway 192.168.100.1 sriov-subnet
```

### 2. 创建SR-IOV端口
```bash
# 创建SR-IOV端口
openstack port create --network sriov-net --vnic-type direct \
  --binding-profile '{"physical_network": "physnet1", "pci_vendor_info": "8086:10ed", "pci_slot": "0000:03:10.0"}' \
  sriov-port
```

### 3. 创建Docker网络
```bash
# 获取网络ID
net_id=$(openstack network show sriov-net -f value -c id)

# 创建kuryr网络
docker network create -d kuryr --ipam-driver=kuryr \
  --subnet=192.168.100.0/24 --gateway=192.168.100.1 \
  -o neutron.net.uuid=$net_id kuryr_sriov_net
```

### 4. 启动容器
```bash
# 使用SR-IOV网络启动容器
docker run -it --net=kuryr_sriov_net --ip=192.168.100.10 ubuntu:latest
```

## 工作原理

### 1. **分工明确**
- **Neutron**: 管理 SR-IOV 硬件和 VF 分配，通过 `physical_device_mappings` 映射
- **Kuryr**: 处理 Docker 网络请求，从 Neutron 端口获取 PCI 信息

### 2. **端口绑定流程**
1. Docker 创建网络请求
2. Kuryr 调用 Neutron API 创建端口
3. Neutron SR-IOV agent 分配 VF 并设置 `binding:profile`
4. Kuryr 读取 `binding:profile['pci_slot']` 信息
5. Kuryr 将 VF 绑定到容器

### 3. **关键配置项**
- **Kuryr 需要**: `enabled_port_drivers` 包含 sriov 驱动
- **Neutron 需要**: `physical_device_mappings` 映射物理设备

## 故障排除

### 1. 检查Kuryr驱动加载
```bash
kubectl exec -n openstack kuryr-libnetwork-xxx -- \
  grep -A5 "enabled_port_drivers" /etc/kuryr/kuryr.conf
```

### 2. 检查SR-IOV硬件
```bash
kubectl exec -n openstack kuryr-libnetwork-xxx -- \
  find /sys/bus/pci/devices -name "sriov_numvfs"
```

### 3. 验证Neutron配置
```bash
# 检查SR-IOV agent
openstack network agent list --agent-type nic-switch

# 检查mechanism drivers
openstack extension list | grep sriovnicswitch
```

这样配置后，Kuryr-libnetwork 就能够支持 SR-IOV 高性能网络了，而 `physical_device_mappings` 的配置在 Neutron 端处理。