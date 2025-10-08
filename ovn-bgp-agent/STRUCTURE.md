# OVN BGP Agent 项目结构文档

本文档详细说明了 OVN BGP Agent 的镜像构建和 Helm Chart 部署的完整项目结构。

## 一、项目概述

OVN BGP Agent 项目分为两个独立的代码仓库:

1. **镜像构建** (openstack-helm-images): 构建 OVN BGP Agent 容器镜像
2. **Helm Chart** (openstack-helm): 部署和管理 OVN BGP Agent 到 Kubernetes

## 二、镜像项目结构

### 仓库位置

提交到: `https://github.com/openstack/openstack-helm-images`

### 目录结构

```
openstack-helm-images/
└── ovn-bgp-agent/
    ├── Dockerfile.ubuntu_noble       # Ubuntu 24.04 LTS 镜像
    ├── Dockerfile.ubuntu_jammy       # Ubuntu 22.04 LTS 镜像
    ├── build.sh                      # 镜像构建脚本
    └── README.rst                    # 镜像使用文档
```

### 镜像设计原则

#### 1. 最小化原则
- 只包含 Python 运行环境和 ovn-bgp-agent
- 使用多阶段构建减小镜像体积
- 不包含 FRR(通过 sidecar 容器部署)

#### 2. 安全性原则
- 非 root 用户运行 (UID 42494)
- 最小权限设计
- 只读根文件系统(通过 Kubernetes securityContext 配置)

#### 3. 标准化原则
- 遵循 OpenStack-Helm 镜像规范
- 兼容 Kolla UID/GID 体系
- 支持多架构构建(amd64/arm64)

### UID/GID 分配

```
UID 42494: ovn-bgp-agent 用户 (主用户)
GID 42494: ovn-bgp-agent 组 (主组)
GID 42424: openvswitch 组 (补充组,用于访问 OVS socket)
```

**说明**:
- UID 42494 需要向 Kolla 项目注册
- GID 42424 与宿主机 openvswitch 组保持一致
- 补充组用于读取 `/run/openvswitch/db.sock`

### 运行时依赖

镜像中包含的运行时依赖:
- `python3`: Python 运行环境
- `iproute2`: 网络配置工具(ip 命令)
- `iptables`: 防火墙规则管理
- `openvswitch-common`: OVS 客户端工具(ovs-vsctl, ovn-nbctl 等)
- `jq`: JSON 处理工具(用于读取 ConfigMap)
- `sudo`: 用于 privsep 权限提升
- `ca-certificates`: SSL 证书

### 构建参数

```bash
# 环境变量
DISTRO=ubuntu_noble              # 或 ubuntu_jammy
PROJECT_REF=master               # ovn-bgp-agent 分支/标签
REGISTRY=docker.io               # 镜像仓库地址
IMAGE_PREFIX=openstackhelm       # 镜像前缀
PUSH=true                        # 是否推送镜像

# 构建示例
./build.sh
```

## 三、Helm Chart 项目结构

### 仓库位置

提交到: `https://github.com/openstack/openstack-helm`

### 完整目录结构

```
openstack-helm/
└── ovn-bgp-agent/
    ├── Chart.yaml                              # Chart 元数据
    ├── values.yaml                             # 默认配置值
    ├── README.md                               # 用户使用文档
    ├── NOTES.txt                               # 安装后提示信息
    ├── STRUCTURE.md                            # 本文档
    │
    ├── templates/                              # Kubernetes 资源模板
    │   ├── bin/                                # Shell 脚本模板
    │   │   ├── _ovn-bgp-agent.sh.tpl          # Agent 启动脚本
    │   │   ├── _frr-init.sh.tpl               # FRR 初始化和网关发现
    │   │   ├── _frr-config-gen.sh.tpl         # FRR 配置生成
    │   │   └── _image-repo-sync.sh.tpl        # 镜像同步脚本
    │   │
    │   ├── configmap-bin.yaml                  # 脚本 ConfigMap
    │   ├── configmap-etc.yaml                  # 配置文件 ConfigMap
    │   ├── configmap-asn.yaml                  # Leaf ASN 映射 ConfigMap
    │   ├── serviceaccount.yaml                 # ServiceAccount
    │   ├── service-metrics.yaml                # Metrics Service (可选)
    │   ├── daemonset-ovn-bgp-agent.yaml        # 主 DaemonSet
    │   ├── poddisruptionbudget.yaml            # PodDisruptionBudget
    │   ├── priorityclass.yaml                  # PriorityClass
    │   ├── networkpolicy.yaml                  # NetworkPolicy (可选)
    │   └── job-image-repo-sync.yaml            # 镜像同步 Job
    │
    ├── examples/                               # 示例配置文件
    │   └── configmap-asn-example.yaml          # ASN 映射示例
    │
    └── values_overrides/                       # Values 覆盖示例
        ├── example.yaml                        # 基础配置示例
        ├── evpn.yaml                           # EVPN 配置示例
        └── production.yaml                     # 生产环境配置
```

## 四、核心组件设计

### 1. 智能 BGP 配置

#### Server ASN 自动生成

基于 IP 地址的确定性 ASN 生成算法:

```bash
ASN = 4200000000 + (octet2 × 65536) + (octet3 × 256) + octet4
```

**示例**:
```
10.0.192.111 → AS 4200049263  (Server)
10.0.193.111 → AS 4200049519  (Server)
10.1.192.111 → AS 4200114799  (Server)
```

**实现位置**: `templates/bin/_frr-init.sh.tpl` 中的 `ip_to_asn()` 函数

**优点**:
- ✅ 无需手动管理 ASN
- ✅ IP 唯一则 ASN 唯一,不会冲突
- ✅ Pod 重启后 ASN 保持不变
- ✅ 适用于大规模分布式部署
- ✅ 使用 IANA 保留的 32-bit 私有 ASN 范围 (4200000000-4294967294)

#### Leaf ASN 映射管理

Leaf 交换机的 ASN 通过 ConfigMap 管理:

```yaml
# ConfigMap: ovn-bgp-agent-asn
{
  "10.0.192.0/24": "65001",  # Rack1 → Leaf-1
  "10.0.193.0/24": "65002",  # Rack2 → Leaf-2
  "10.0.194.0/24": "65003"   # Rack3 → Leaf-3
}
```

**实现位置**: `templates/configmap-asn.yaml`

**特性**:
- 首次安装时从 `values.yaml` 创建
- 后续 `helm upgrade` 不会覆盖 (使用 `lookup` 函数检测)
- 支持运行时编辑,无需重启 Pod (新 Pod 自动读取)
- `helm uninstall` 时自动删除

**关键实现**:
```yaml
{{- $existingCM := lookup "v1" "ConfigMap" .Release.Namespace "ovn-bgp-agent-asn" }}
{{- if not $existingCM }}
# 只在 ConfigMap 不存在时创建
{{- end }}
```

#### 网关 IP 自动发现

三级 Fallback 机制 (实现位置: `_frr-init.sh.tpl`):

**1. 路由表查询** (discover_from_route)
```bash
ip -4 route show dev br-ex 2>/dev/null | \
    grep '^default' | awk '{print $3}' | head -n1
```

**2. ARP 扫描** (discover_from_arp)
```bash
# 并发 ping 子网首尾 IP
for gw in "$first_ip" "$last_ip"; do
    ping -c 2 -W 3 "$gw" >/dev/null 2>&1 &  # 保留 & 符号!
done
wait
sleep 1

# 检查 ARP 表
ip neigh show dev br-ex | grep "^${gw} "
```

**3. 子网约定** (fallback)
```bash
# 使用 network + 1 (通常是 .1)
read first_ip last_ip <<< $(get_subnet_info "$ip_cidr")
echo "$first_ip detection:fallback"
```

### 2. 脚本模块化设计

#### frr-init.sh.tpl (初始化脚本)

**职责**:
- 读取节点网络信息 (br-ex IP/子网)
- 自动生成 Server ASN
- 发现 Leaf 网关 IP
- 从 ConfigMap 查询 Leaf ASN
- 验证网络连通性 (ping 测试)
- 导出环境变量并调用配置生成脚本

**关键函数**:
```bash
ip_to_asn()              # IP → ASN 转换
get_subnet_info()        # 计算子网首尾 IP
discover_from_route()    # 路由表查询网关
discover_from_arp()      # ARP 扫描发现网关
discover_gateway_auto()  # 三级 fallback 主函数
discover_leaf_asn()      # 从 ConfigMap 查询 Leaf ASN
```

**输出格式**:
```bash
=== BGP Configuration ===
Node:           worker1
Interface:      br-ex (10.0.192.111/24)
Subnet:         10.0.192.0/24

Local (Server):
  IPv4:         10.0.192.111
  ASN:          4200049263 (auto-generated)
  Router ID:    10.0.192.111

Peer (Leaf Switch):
  IPv4:         10.0.192.1
  ASN:          65001 (from ConfigMap)
  Discovery:    route
  Reachable:    yes

==================================
```

#### frr-config-gen.sh.tpl (配置生成脚本)

**职责**:
- 生成 `/etc/frr/daemons` 文件
- 生成 `/etc/frr/frr.conf` 文件
- 配置 BGP 基础参数
- 配置 IPv4 Unicast 邻居 (到 Leaf)
- 配置 L2VPN EVPN 邻居 (到 RR,可选)
- 设置文件权限

**生成的配置示例**:
```
router bgp 4200049263
 bgp router-id 10.0.192.111
 bgp log-neighbor-changes
 bgp graceful-restart
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 
 ! eBGP Peering to Leaf Switch
 neighbor 10.0.192.1 remote-as 65001
 neighbor 10.0.192.1 description "Leaf-Switch"
 neighbor 10.0.192.1 timers 3 10
 
 address-family ipv4 unicast
  neighbor 10.0.192.1 activate
  neighbor 10.0.192.1 soft-reconfiguration inbound
 exit-address-family
```

#### ovn-bgp-agent.sh.tpl (Agent 启动脚本)

**职责**:
- 等待 FRR 初始化完成
- 加载 BGP 配置环境变量
- 动态更新 agent 配置文件
- 等待 FRR 守护进程就绪
- 启动 OVN BGP Agent
- 标记 Pod 就绪

**关键改进**: 添加了路由表 ID 动态查找:
```bash
# 查找 br-ex 路由表 ID
BR_EX_TABLE_ID=$(ip route show table all | grep "table" | \
    grep "br-ex" | head -n1 | awk '{print $NF}')

# 如果找不到,使用默认值或创建
if [ -z "$BR_EX_TABLE_ID" ]; then
    BR_EX_TABLE_ID=10
    echo "$BR_EX_TABLE_ID br-ex" >> /etc/iproute2/rt_tables
fi
```

### 3. 容器架构设计

#### Init Container: init-frr-config

```yaml
名称: init-frr-config
镜像: ovn-bgp-agent (复用主镜像)
职责: 初始化 FRR 配置
运行: /tmp/frr-init.sh
挂载:
  - /tmp (临时文件)
  - /etc/frr (FRR 配置目录, emptyDir)
  - /tmp/pod-shared (共享目录, emptyDir)
  - /etc/ovn-bgp-agent/asn-mapping (ASN 映射 ConfigMap, 只读)
输出:
  - /etc/frr/frr.conf
  - /etc/frr/daemons
  - /etc/frr/vtysh.conf
  - /tmp/pod-shared/bgp-config.env
```

**环境变量**:
- `NODE_IP`: 节点 IP (来自 Downward API)
- `NODE_NAME`: 节点名称 (来自 Downward API)

#### Container 1: frr

```yaml
名称: frr
镜像: quay.io/frrouting/frr:10.4.1
职责: 运行 FRR 路由守护进程 (bgpd, zebra)
命令: /usr/lib/frr/docker-start
用户: root (FRR 要求)
权限:
  - privileged: true
  - capabilities: NET_ADMIN, NET_RAW
挂载:
  - /tmp (临时文件)
  - /etc/frr (配置目录, 来自 init)
  - /run/frr (运行时 socket)
  - /var/lib/frr (状态数据)
  - /var/tmp/frr (临时文件)
探针:
  - liveness: /usr/lib/frr/watchfrr.sh
  - readiness: vtysh -c 'show running-config'
```

#### Container 2: ovn-bgp-agent

```yaml
名称: ovn-bgp-agent
镜像: ghcr.io/fivetime/openstackhelm/ovn-bgp-agent:master-ubuntu_noble
职责: 运行 OVN BGP Agent
用户: UID 42494 (非 root)
权限:
  - privileged: true
  - capabilities: NET_ADMIN, SYS_ADMIN, NET_RAW
挂载:
  - /run/openvswitch (OVS socket, hostPath)
  - /run/ovn (OVN socket, hostPath)
  - /run/frr (FRR socket, 共享 emptyDir)
  - /tmp/pod-shared (共享目录)
探针:
  - liveness: pgrep -f 'ovn-bgp-agent'
  - readiness: test -f /tmp/pod-shared/ready
```

#### Container 3: frr-exporter (可选)

```yaml
名称: frr-exporter
镜像: docker.io/tynany/frr_exporter:v1.8.1
职责: 导出 FRR metrics 到 Prometheus
条件: .Values.monitoring.enabled
端口: 9342 (metrics)
```

### 4. ConfigMap 管理策略

#### configmap-bin (脚本 ConfigMap)

```yaml
名称: ovn-bgp-agent-bin
内容:
  - ovn-bgp-agent.sh: Agent 启动脚本
  - frr-init.sh: FRR 初始化脚本
  - frr-config-gen.sh: FRR 配置生成
  - image-repo-sync.sh: 镜像同步 (可选)
权限: 0555 (可执行)
行为: 每次 helm upgrade 都会更新
用途: Pod 启动时挂载为脚本文件
```

#### configmap-etc (配置 ConfigMap)

```yaml
名称: ovn-bgp-agent-etc
内容:
  - ovn-bgp-agent.conf: Agent 主配置文件
权限: 0444 (只读)
行为: 每次 helm upgrade 都会更新
特点: 
  - 使用 helm-toolkit.utils.to_ini 函数生成 INI 格式
  - 自动注入 OVN NB/SB 连接串
```

#### configmap-asn (ASN 映射 ConfigMap)

```yaml
名称: ovn-bgp-agent-asn
内容:
  - mapping.json: Leaf ASN 映射 (JSON 格式)
权限: 0444 (只读)
行为: 
  - 首次安装: 从 values.yaml 创建
  - 后续 upgrade: 不修改 (使用 lookup 检测)
  - 运行时: 可手动编辑
  - 卸载: 自动删除
特殊性: 运维数据,不应频繁变更
实现: 使用 Helm lookup 函数检测是否存在
```

**lookup 函数要求**:
- Helm 3.2+
- Kubernetes RBAC: get/list ConfigMaps

## 五、网络架构

### 典型 Leaf-Spine 拓扑

```
                    [Spine]
                  AS 65000 (16-bit)
                  192.168.100.1 (Loopback)
                      |
         +------------+------------+
         |                         |
     [Leaf-1]                  [Leaf-2]
     AS 65001                  AS 65002
     10.0.192.1                10.0.193.1
         |                         |
    +----+----+              +-----+-----+
    |         |              |           |
[Server-1][Server-2]    [Server-3] [Server-4]
AS 4200049263           AS 4200049519
10.0.192.111            10.0.193.111
  (eBGP)                  (eBGP)
```

### BGP 会话类型

| 会话类型 | 本端 | 对端 | BGP 类型 | Address Family | 用途 |
|---------|------|------|---------|----------------|------|
| Server-Leaf | Server | Leaf | eBGP | IPv4 Unicast | 路由通告 (underlay) |
| Server-Spine | Server | Spine | iBGP | L2VPN EVPN | VXLAN 路由 (overlay, 可选) |
| Leaf-Spine | Leaf | Spine | eBGP | IPv4 + EVPN | 汇聚层 |

### ASN 分配策略

| 组件 | ASN 范围 | 分配方式 | 示例 | 类型 |
|------|---------|---------|------|------|
| Server | 4200000000 - 4294967295 | 基于 IP 自动生成 | AS 4200049263 | 32-bit |
| Leaf | 65001 - 65534 | 手动规划 (ConfigMap) | AS 65001 | 16-bit |
| Spine | 64512 - 65534 | 手动规划 | AS 65000 | 16-bit |

**ASN 范围说明**:
- 16-bit 私有 ASN: 64512-65534 (RFC 6996)
- 32-bit 私有 ASN: 4200000000-4294967294 (RFC 6996)

## 六、部署模式

### 1. 集中式部署 (Centralized)

**适用场景**: 租户网络通过网关端口暴露

```yaml
labels:
  agent:
    node_selector_key: openstack-network-node
    node_selector_value: enabled

conf:
  ovn_bgp_agent:
    DEFAULT:
      driver: nb_ovn_bgp_driver
      expose_tenant_networks: true
```

**特点**:
- 部署在网络节点 (运行 OVN Gateway)
- 流量路径: VM → OVN Router → Network Node → BGP → Leaf
- 使用 centralized router port (cr-lrp)

**流量示例**:
```
VM (172.16.1.10)
    ↓
OVN Distributed Router
    ↓
Network Node (10.0.192.111, AS 4200049263)
    ↓ BGP 通告 172.16.1.0/24
Leaf (10.0.192.1, AS 65001)
    ↓
Spine → 外部网络
```

### 2. 分布式部署 (Distributed)

**适用场景**: Provider 网络和 Floating IP

```yaml
labels:
  agent:
    node_selector_key: openstack-compute-node
    node_selector_value: enabled

conf:
  ovn_bgp_agent:
    DEFAULT:
      driver: nb_ovn_bgp_driver
      expose_tenant_networks: false  # 通常不暴露租户网络
```

**特点**:
- 部署在所有计算节点
- 流量路径: VM → Compute Node → BGP → Leaf
- 直接通告 VM IP (/32)

**流量示例**:
```
VM with FIP (203.0.113.10)
    ↓
Compute Node (10.0.192.111, AS 4200049263)
    ↓ BGP 通告 203.0.113.10/32
Leaf (10.0.192.1, AS 65001)
    ↓
Spine → Internet
```

### 3. 混合部署 (Hybrid)

同时部署在网络节点和计算节点,使用不同的 node selector。

## 七、配置详解

### values.yaml 核心配置

#### BGP 基础配置

```yaml
bgp:
  enabled: true
  
  # Peer IP 发现策略
  peer_ip: ""  # 选项:
               # "" 或 "detection" - 自动发现 (推荐)
               # "first" - 子网第一个 IP
               # "last" - 子网最后一个 IP
               # "10.0.192.1" - 固定 IP
  
  # Leaf ASN 映射 (仅首次安装使用)
  asn_mapping:
    "10.0.192.0/24": "65001"
    "10.0.193.0/24": "65002"
```

#### EVPN 配置

```yaml
bgp:
  evpn:
    enabled: false
    rr_ip: "192.168.100.1"    # Spine Loopback IP
    rr_asn: "65000"           # Spine ASN (16-bit)
```

#### Driver 配置

```yaml
conf:
  ovn_bgp_agent:
    DEFAULT:
      driver: nb_ovn_bgp_driver  # 推荐
      bridge_mappings: external:br-ex
      ovsdb_connection: unix:/run/openvswitch/db.sock
      
      # 驱动选项:
      # - nb_ovn_bgp_driver: NB DB (推荐)
      # - ovn_bgp_driver: SB DB (传统)
      # - ovn_evpn_driver: EVPN 支持
      # - ovn_stretched_l2_bgp_driver: L2 扩展
```

#### 资源限制

```yaml
pod:
  resources:
    enabled: true
    ovn_bgp_agent:
      requests:
        memory: "512Mi"   # 建议从 256Mi 提升
        cpu: "500m"       # 建议从 200m 提升
      limits:
        memory: "2Gi"     # 建议从 1Gi 提升
        cpu: "2000m"
    frr:
      requests:
        memory: "256Mi"   # 建议从 128Mi 提升
        cpu: "200m"       # 建议从 100m 提升
      limits:
        memory: "512Mi"
        cpu: "500m"
```

## 八、部署流程

### 标准部署步骤

```bash
# 1. 标记节点
kubectl label nodes worker1 openstack-network-node=enabled

# 2. 配置 Leaf ASN 映射 (在 values.yaml 中)
cat > custom-values.yaml <<EOF
bgp:
  enabled: true
  asn_mapping:
    "10.0.192.0/24": "65001"
    "10.0.193.0/24": "65002"
EOF

# 3. 安装 Chart
helm install ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack \
  --create-namespace \
  --values custom-values.yaml

# 4. 验证部署
kubectl -n openstack get pods -l application=ovn-bgp-agent
kubectl -n openstack logs daemonset/ovn-bgp-agent -c init-frr-config

# 5. 验证 BGP 会话
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp summary"
```

### 运行时更新 Leaf ASN

```bash
# 方法1: 直接编辑
kubectl -n openstack edit configmap ovn-bgp-agent-asn

# 方法2: 使用 patch
kubectl -n openstack patch configmap ovn-bgp-agent-asn \
  --type merge -p '{"data":{"mapping.json":"..."}}'

# 新启动的 Pod 会自动使用新配置
# 已运行的 Pod 需要重启 (可选)
kubectl -n openstack rollout restart daemonset ovn-bgp-agent
```

## 九、监控和故障排查

### 检查点清单

| 检查项 | 命令 | 预期结果 |
|-------|------|---------|
| Pod 状态 | `kubectl get pods -l application=ovn-bgp-agent` | Running 2/2 或 3/3 |
| Init 日志 | `kubectl logs -c init-frr-config` | BGP Configuration 输出 |
| FRR 状态 | `kubectl exec -c frr -- vtysh -c "show bgp summary"` | Established |
| Agent 日志 | `kubectl logs -c ovn-bgp-agent` | No errors |
| 路由通告 | `kubectl exec -c frr -- vtysh -c "show ip bgp"` | 有路由条目 |

### 常见问题及解决方案

#### 1. BGP 会话未建立

**症状**: `show bgp summary` 显示 `Idle` 或 `Active`

**排查步骤**:
```bash
# 1. 查看初始化日志
kubectl -n openstack logs daemonset/ovn-bgp-agent -c init-frr-config

# 2. 检查 Leaf 连通性
kubectl -n openstack exec -c ovn-bgp-agent -- ping -c 3 10.0.192.1

# 3. 检查 ASN 配置
kubectl -n openstack exec -c frr -- cat /etc/frr/frr.conf | grep "remote-as"

# 4. 检查 ConfigMap
kubectl -n openstack get configmap ovn-bgp-agent-asn -o yaml
```

**可能原因及解决**:
1. Leaf IP 不可达 → 检查网络连接
2. ASN 配置错误 → 编辑 ConfigMap
3. Leaf 侧未配置对等 → 配置 Leaf 交换机
4. 防火墙阻止 TCP/179 → 开放 BGP 端口

#### 2. ConfigMap 中找不到 ASN 映射

**症状**: Init 容器失败,日志显示 "No Leaf ASN mapping found"

**排查步骤**:
```bash
# 1. 检查节点子网
kubectl -n openstack exec -c init-frr-config -- \
  ip -4 route show dev br-ex | grep -v default

# 2. 查看 ConfigMap 内容
kubectl -n openstack get configmap ovn-bgp-agent-asn \
  -o jsonpath='{.data.mapping\.json}' | jq .

# 3. 添加缺失的映射
kubectl -n openstack edit configmap ovn-bgp-agent-asn
```

#### 3. Agent 无法连接 OVN 数据库

**症状**: Agent 容器 CrashLoopBackOff

**排查步骤**:
```bash
# 1. 测试 OVN NB 连接
kubectl -n openstack exec -c ovn-bgp-agent -- \
  ovn-nbctl --db=tcp://ovn-ovsdb-nb:6641 show

# 2. 检查 Service
kubectl -n openstack get svc ovn-ovsdb-nb

# 3. 检查 endpoints.yaml 配置
helm get values ovn-bgp-agent -n openstack
```

## 十、性能指标

### 资源使用建议 (已修正)

| 规模 | VMs | Agent 内存 | Agent CPU | FRR 内存 | FRR CPU |
|------|-----|-----------|-----------|----------|---------|
| 小型 | <100 | 256Mi | 200m | 128Mi | 100m |
| 中型 | 100-500 | 512Mi | 500m | 256Mi | 200m |
| 大型 | 500-1000 | 1Gi | 1000m | 512Mi | 500m |
| 超大型 | >1000 | 2Gi | 2000m | 512Mi | 500m |

### BGP 收敛时间

| 场景 | 预期时间 |
|------|---------|
| 单条路由通告 | <1s |
| 100 条路由 | <5s |
| 1000 条路由 | <30s |
| 完全收敛 (5000+ 路由) | <2min |

## 十一、安全考虑

### 必需的权限

```yaml
securityContext:
  privileged: true  # 或使用精细化 capabilities
  capabilities:
    add:
      - NET_ADMIN    # 必需: 修改内核路由表
      - SYS_ADMIN    # 必需: 网络命名空间操作
      - NET_RAW      # 必需: ARP 扫描
```

### 网络访问要求

| 组件 | 路径/地址 | 权限 | 用途 |
|------|----------|------|------|
| OVS Socket | /run/openvswitch/db.sock | 读 | 查询 OVS 信息 |
| OVN NB | tcp://ovn-ovsdb-nb:6641 | 读 | 读取逻辑拓扑 |
| OVN SB | tcp://ovn-ovsdb-sb:6642 | 读 | 读取南向数据库 |
| FRR Socket | /run/frr/zebra.vty | 读写 | 控制 FRR |

### Pod Security Standards

```yaml
# 最低要求: Restricted (不兼容)
# 推荐: Baseline
# 实际: Privileged (由于需要 NET_ADMIN)
```

## 十二、扩展和定制

### 支持的定制点

1. **自定义 Driver**: 通过 `conf.ovn_bgp_agent.DEFAULT.driver`
2. **额外的 Volume 挂载**: 通过 `pod.mounts`
3. **自定义资源限制**: 通过 `pod.resources`
4. **自定义容忍度**: 通过 `pod.tolerations`
5. **自定义节点选择器**: 通过 `labels.agent`

### 示例: 添加自定义挂载

```yaml
pod:
  mounts:
    ovn_bgp_agent:
      ovn_bgp_agent:
        volumeMounts:
          - name: custom-config
            mountPath: /etc/custom
            readOnly: true
        volumes:
          - name: custom-config
            configMap:
              name: my-custom-config
```

## 十三、项目提交清单

### 镜像仓库提交 (openstack-helm-images)

#### 核心文件
- [ ] `ovn-bgp-agent/Dockerfile.ubuntu_noble`
- [ ] `ovn-bgp-agent/Dockerfile.ubuntu_jammy`
- [ ] `ovn-bgp-agent/build.sh`
- [ ] `ovn-bgp-agent/README.rst`

#### 关键修复
- [ ] Sudo 配置限制到 ovn-bgp-agent 用户
- [ ] Ubuntu 24.04 使用 --break-system-packages
- [ ] 正确的 Python 路径 (3.10 vs 3.12)

#### CI/CD
- [ ] `.zuul.yaml` (添加构建 jobs)
- [ ] 向 Kolla 注册 UID 42494

### Chart 仓库提交 (openstack-helm)

#### 核心文件
- [ ] `ovn-bgp-agent/Chart.yaml`
- [ ] `ovn-bgp-agent/values.yaml`
- [ ] `ovn-bgp-agent/README.md`
- [ ] `ovn-bgp-agent/NOTES.txt`
- [ ] `ovn-bgp-agent/STRUCTURE.md`

#### 模板文件
- [ ] `templates/bin/_ovn-bgp-agent.sh.tpl`
- [ ] `templates/bin/_frr-init.sh.tpl` (修复字符编码)
- [ ] `templates/bin/_frr-config-gen.sh.tpl` (修复字符编码)
- [ ] `templates/bin/_image-repo-sync.sh.tpl`
- [ ] `templates/configmap-bin.yaml`
- [ ] `templates/configmap-etc.yaml`
- [ ] `templates/configmap-asn.yaml`
- [ ] `templates/serviceaccount.yaml`
- [ ] `templates/service-metrics.yaml`
- [ ] `templates/daemonset-ovn-bgp-agent.yaml`
- [ ] `templates/poddisruptionbudget.yaml`
- [ ] `templates/priorityclass.yaml`
- [ ] `templates/networkpolicy.yaml`
- [ ] `templates/job-image-repo-sync.yaml`

#### 示例文件
- [ ] `examples/configmap-asn-example.yaml`
- [ ] `values_overrides/example.yaml`
- [ ] `values_overrides/evpn.yaml`
- [ ] `values_overrides/production.yaml`

#### 关键修复清单
- [ ] 移除所有中文字符编码错误
- [ ] 保留 ARP 扫描中的 `&` 符号
- [ ] 添加路由表 ID 动态查找逻辑
- [ ] 更新资源限制推荐值
- [ ] 完善健康检查逻辑

## 十四、关键创新点

### 1. 零配置部署
- Server ASN 基于 IP 自动生成 (32-bit 确定性算法)
- Leaf 网关 IP 三级自动发现 (路由表 → ARP → 约定)
- 无需手动规划 Server ASN

### 2. 智能 ConfigMap 管理
- 首次安装创建,后续不覆盖 (使用 lookup 函数)
- 支持运行时编辑,新 Pod 自动生效
- 卸载时自动清理

### 3. 模块化脚本设计
- 职责清晰: init → config-gen → agent start
- 可复用的函数库 (ip_to_asn, discover_gateway_auto 等)
- 易于测试和调试

### 4. 灵活的部署模式
- 支持集中式/分布式/混合部署
- 通过 node selector 灵活调度
- 适应不同网络架构

### 5. 完善的故障排查
- 详细的初始化日志输出
- 清晰的错误提示和解决建议
- 便捷的验证命令

## 十五、测试要求

### 代码质量检查

```bash
# Shell 脚本检查
shellcheck templates/bin/*.tpl

# Helm Chart 语法检查
helm lint ovn-bgp-agent

# YAML 语法检查
yamllint ovn-bgp-agent/templates/*.yaml
```

### 功能测试

#### 测试场景 1: 基础部署
```bash
# 1. 安装
helm install ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack --create-namespace

# 2. 验证 Pod 启动
kubectl -n openstack get pods -l application=ovn-bgp-agent

# 3. 验证 BGP 会话
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp summary"
```

#### 测试场景 2: ASN 映射管理
```bash
# 1. 查看初始映射
kubectl -n openstack get configmap ovn-bgp-agent-asn -o yaml

# 2. 添加新映射
kubectl -n openstack edit configmap ovn-bgp-agent-asn

# 3. 重启 Pod 验证
kubectl -n openstack rollout restart daemonset ovn-bgp-agent

# 4. Helm upgrade 验证 ConfigMap 保持
helm upgrade ovn-bgp-agent ./ovn-bgp-agent --reuse-values
kubectl -n openstack get configmap ovn-bgp-agent-asn -o yaml
```

#### 测试场景 3: 网关发现
```bash
# 测试三种发现模式
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --set bgp.peer_ip="" --reuse-values       # 自动发现
  
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --set bgp.peer_ip="first" --reuse-values  # 使用首 IP

helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --set bgp.peer_ip="10.0.192.1" --reuse-values  # 固定 IP
```

#### 测试场景 4: EVPN
```bash
# 启用 EVPN
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --set bgp.evpn.enabled=true \
  --set bgp.evpn.rr_ip="192.168.100.1" \
  --set bgp.evpn.rr_asn="65000" \
  --reuse-values

# 验证 EVPN 会话
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp l2vpn evpn summary"
```

### 性能测试

#### 路由收敛测试
```bash
# 1. 创建 100 个浮动 IP
for i in {1..100}; do
  openstack floating ip create external
done

# 2. 观察收敛时间
kubectl -n openstack logs -f daemonset/ovn-bgp-agent -c ovn-bgp-agent

# 3. 验证路由数量
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show ip bgp summary"
```

#### 资源使用测试
```bash
# 监控资源使用
kubectl -n openstack top pods -l application=ovn-bgp-agent

# 查看详细指标
kubectl -n openstack describe pod <pod-name>
```

## 十六、后续改进方向

### 短期 (3-6 个月)

- [ ] **Prometheus Metrics 集成**
    - 添加自定义 metrics (BGP 会话状态, 路由数量)
    - 集成 frr_exporter
    - 提供 Grafana Dashboard

- [ ] **BFD 支持**
    - 启用 BFD 快速故障检测
    - 配置 BFD timers

- [ ] **BGP Graceful Restart**
    - 完善 graceful restart 配置
    - 减少升级时的流量中断

- [ ] **健康检查改进**
    - 更精确的 readiness probe (检查 BGP 会话状态)
    - 添加 startup probe

### 中期 (6-12 个月)

- [ ] **IPv6 支持**
    - IPv6 Only 环境支持
    - Dual-stack 支持
    - IPv6 ASN 生成算法

- [ ] **Route Aggregation**
    - 支持路由聚合
    - 减少通告的路由数量

- [ ] **ECMP 支持**
    - 多 Leaf 的 ECMP
    - 负载均衡优化

- [ ] **CI/CD 集成**
    - 集成 OpenStack-Helm CI
    - 自动化测试

### 长期 (12+ 个月)

- [ ] **BGP Route Policy**
    - 支持 route-map
    - 支持 prefix-list
    - 支持 community

- [ ] **自动化拓扑发现**
    - 自动发现 Leaf-Spine 拓扑
    - 动态 ASN 分配

- [ ] **IPAM 集成**
    - 集成 NetBox
    - 自动化 IP 和 ASN 管理

- [ ] **Multi-tenancy**
    - VRF 支持
    - 租户隔离

## 十七、参考资源

### 官方文档
- **OVN BGP Agent**: https://docs.openstack.org/ovn-bgp-agent/latest/
- **OpenStack Helm**: https://docs.openstack.org/openstack-helm/latest/
- **FRRouting**: https://docs.frrouting.org/
- **Helm**: https://helm.sh/docs/

### RFC 标准
- **RFC 4271**: BGP-4 (Border Gateway Protocol)
- **RFC 6996**: Private ASN Range (64512-65534, 4200000000-4294967294)
- **RFC 7938**: BGP Best Practices for IXPs
- **RFC 7432**: BGP MPLS-Based EVPN
- **RFC 8365**: Framework for Data Center Network Virtualization over Layer 3
- **RFC 4724**: Graceful Restart Mechanism for BGP

### 社区资源
- **OpenStack Discuss**: https://lists.openstack.org/mailman3/lists/openstack-discuss.lists.openstack.org/
- **Kolla UID Registry**: https://github.com/openstack/kolla/blob/master/kolla/common/users.py
- **OpenStack Helm GitHub**: https://github.com/openstack/openstack-helm
- **FRR Community**: https://frrouting.org/community.html

### 相关项目
- **MetalLB**: Kubernetes load-balancer with BGP
- **Calico**: Kubernetes networking with BGP
- **GoBGP**: BGP implementation in Go
- **Bird**: Internet routing daemon

## 十八、贡献指南

### 提交流程

1. **Fork 仓库**
   ```bash
   # 镜像仓库
   git clone https://opendev.org/openstack/openstack-helm-images
   
   # Chart 仓库
   git clone https://opendev.org/openstack/openstack-helm
   ```

2. **创建功能分支**
   ```bash
   git checkout -b feature/my-feature
   ```

3. **提交更改**
   ```bash
   git add .
   git commit -s -m "Add feature: description"
   ```

4. **推送到 Gerrit**
   ```bash
   git review
   ```

### 代码规范

#### Shell 脚本
- 使用 `set -ex` 启用调试
- 函数使用 snake_case 命名
- 添加注释说明复杂逻辑
- 通过 ShellCheck 检查

#### YAML 文件
- 2 空格缩进
- 使用 `---` 分隔文档
- 添加注释说明配置用途
- 通过 yamllint 检查

#### Helm Templates
- 使用 helm-toolkit snippets
- 遵循 OpenStack-Helm 命名规范
- 添加 if 条件保护可选功能
- 使用 `include` 而非 `template`

### 测试要求

- [ ] 所有 Shell 脚本通过 ShellCheck
- [ ] Helm Chart 通过 `helm lint`
- [ ] 提供测试用例和验证步骤
- [ ] 更新相关文档 (README, STRUCTURE)
- [ ] 添加示例配置 (values_overrides)

### 文档要求

- [ ] 更新 README.md (如有用户可见变更)
- [ ] 更新 STRUCTURE.md (如有架构变更)
- [ ] 更新 NOTES.txt (如有部署后操作变更)
- [ ] 提供配置示例
- [ ] 添加故障排查指南

### Review 流程

1. 提交到 Gerrit: https://review.opendev.org
2. 等待 CI 检查通过
3. 等待社区 Review (+1/+2)
4. Core reviewer 批准 (+2, Approved)
5. 自动合并到主分支

## 十九、常见问题 (FAQ)

### Q1: 为什么 Server 使用 32-bit ASN 而 Leaf 使用 16-bit?

**A**:
- Server ASN 需要大范围 (数万个节点) → 使用 32-bit (4.2B-4.3B)
- Leaf ASN 数量有限 (数百个机架) → 使用 16-bit (64512-65534)
- 32-bit 和 16-bit ASN 可以互操作

### Q2: ConfigMap 为什么在 helm upgrade 时不更新?

**A**: Leaf ASN 映射是运维数据,不是配置模板。设计目标:
- 允许运行时编辑而不影响已有 Pod
- 避免误操作导致 ASN 映射丢失
- 支持独立于 Helm 管理

### Q3: 为什么需要 privileged 权限?

**A**: OVN BGP Agent 需要:
- 修改内核路由表 (ip route add/del)
- 操作网络命名空间 (ip netns)
- 发送 ARP 请求 (用于网关发现)

未来可能改为使用精细化 capabilities。

### Q4: 如何在生产环境中使用?

**A**: 推荐配置:
```yaml
# 生产环境配置
pod:
  resources:
    enabled: true
    # 根据规模调整资源
  
  tolerations:
    ovn_bgp_agent:
      enabled: true
      # 添加必要的容忍度

manifests:
  priorityclass: true        # 防止驱逐
  poddisruptionbudget: true  # 保证可用性
  networkpolicy: true        # 网络隔离

bgp:
  enabled: true
  peer_ip: "10.0.192.1"      # 生产环境建议固定 IP
  asn_mapping:
    # 完整的机架映射
```

### Q5: 如何监控 BGP 状态?

**A**:
```bash
# 启用 monitoring
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --set monitoring.enabled=true \
  --reuse-values

# 访问 metrics
curl http://<pod-ip>:9342/metrics

# 使用 Prometheus 抓取
# ServiceMonitor 会自动创建
```

## 二十、故障排除矩阵

| 症状 | 可能原因 | 排查命令 | 解决方案 |
|------|---------|---------|---------|
| Pod CrashLoopBackOff | OVN DB 不可达 | `kubectl logs -c ovn-bgp-agent` | 检查 endpoints 配置 |
| BGP Active 状态 | Leaf 未配置 | `kubectl logs -c init-frr-config` | 配置 Leaf 交换机 |
| ASN mapping not found | 缺少子网映射 | `kubectl get cm ovn-bgp-agent-asn` | 添加子网到 ConfigMap |
| Wrong gateway IP | 自动发现失败 | 查看 init 日志 | 设置 `bgp.peer_ip` |
| Init 容器失败 | JQ 解析错误 | `kubectl logs -c init-frr-config` | 检查 mapping.json 格式 |
| 路由未通告 | Driver 配置错误 | `kubectl logs -c ovn-bgp-agent` | 检查 driver 设置 |

## 二十一、版本历史

### v0.1.0 (2025-01-08)
- 初始版本
- 支持 Ubuntu 22.04 和 24.04
- 智能 ASN 生成和网关发现
- ConfigMap 持久化 ASN 映射
- EVPN 支持 (可选)
- 完整的文档和示例

---

**版本**: 1.0  
**最后更新**: 2025-01-08  
**维护者**: OpenStack Helm Team  
**状态**: Ready for Community Review