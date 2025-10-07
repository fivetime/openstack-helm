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
- 不包含 OVS/OVN 工具(假设宿主机已部署)
- 不包含 FRR(通过 sidecar 容器部署)

#### 2. 安全性原则
- 非 root 用户运行 (UID 42494)
- 最小权限设计
- 只读根文件系统(通过 Kubernetes 配置)

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
- `openvswitch-common`: OVS 客户端工具
- `jq`: JSON 处理工具(用于读取 ConfigMap)
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
    │   ├── daemonset-ovn-bgp-agent.yaml        # 主 DaemonSet
    │   ├── poddisruptionbudget.yaml            # PodDisruptionBudget
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
```

**优点**:
- ✅ 无需手动管理 ASN
- ✅ IP 唯一则 ASN 唯一,不会冲突
- ✅ Pod 重启后 ASN 保持不变
- ✅ 适用于大规模分布式部署

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

**特性**:
- 首次安装时从 `values.yaml` 创建
- 后续 `helm upgrade` 不会覆盖
- 支持运行时编辑,无需重启 Pod
- `helm uninstall` 时自动删除

#### 网关 IP 自动发现

三级 Fallback 机制:

```
1. 路由表查询
   ↓ ip route show dev br-ex | grep default
   ↓ (失败)
   
2. ARP 扫描
   ↓ ping 子网首尾 IP + 检查 ARP 表
   ↓ (失败)
   
3. 子网约定
   ↓ 使用 network + 1 (通常是 .1)
```

### 2. 脚本模块化设计

#### frr-init.sh.tpl (初始化脚本)

职责:
- 读取节点网络信息(br-ex IP/子网)
- 自动生成 Server ASN
- 发现 Leaf 网关 IP
- 从 ConfigMap 查询 Leaf ASN
- 验证网络连通性
- 调用配置生成脚本

输出:
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

职责:
- 生成 `/etc/frr/daemons` 文件
- 生成 `/etc/frr/frr.conf` 文件
- 配置 BGP 基础参数
- 配置 IPv4 Unicast 邻居(到 Leaf)
- 配置 L2VPN EVPN 邻居(到 RR,可选)
- 设置文件权限

生成的配置示例:
```
router bgp 4200049263
 bgp router-id 10.0.192.111
 
 ! eBGP to Leaf
 neighbor 10.0.192.1 remote-as 65001
 neighbor 10.0.192.1 description "Leaf-Switch"
 
 address-family ipv4 unicast
  neighbor 10.0.192.1 activate
 exit-address-family
 
 ! iBGP to Route Reflector (if EVPN enabled)
 neighbor 192.168.100.1 remote-as 65000
 address-family l2vpn evpn
  neighbor 192.168.100.1 activate
  advertise-all-vni
 exit-address-family
```

#### ovn-bgp-agent.sh.tpl (Agent 启动脚本)

职责:
- 等待 FRR 就绪
- 等待 OVN 数据库可访问
- 更新配置文件中的运行时参数
- 启动 OVN BGP Agent
- 标记 Pod 就绪

### 3. 容器架构设计

#### Init Container: init-frr-config

```yaml
职责: 初始化 FRR 配置
运行: frr-init.sh
挂载:
  - /tmp (临时文件)
  - /etc/frr (FRR 配置目录)
  - /etc/ovn-bgp-agent/asn-mapping (ASN 映射 ConfigMap)
输出: /etc/frr/frr.conf, /etc/frr/daemons
```

#### Container 1: frr

```yaml
镜像: quay.io/frrouting/frr:10.4.1
职责: 运行 FRR 路由守护进程
命令: /usr/lib/frr/docker-start
权限:
  - privileged: true
  - NET_ADMIN, NET_RAW
端口: 无(本地通信)
探针:
  - liveness: watchfrr.sh
  - readiness: vtysh -c 'show running-config'
```

#### Container 2: ovn-bgp-agent

```yaml
镜像: ghcr.io/fivetime/openstackhelm/ovn-bgp-agent:master-ubuntu_noble
职责: 运行 OVN BGP Agent
用户: UID 42494 (非 root)
权限:
  - privileged: true
  - NET_ADMIN, SYS_ADMIN, NET_RAW
挂载:
  - /run/openvswitch (OVS socket)
  - /run/ovn (OVN socket)
  - /run/frr (FRR socket)
探针:
  - liveness: pgrep ovn-bgp-agent
  - readiness: test -f /tmp/pod-shared/ready
```

### 4. ConfigMap 管理策略

#### configmap-bin (脚本 ConfigMap)

```yaml
名称: ovn-bgp-agent-bin
内容:
  - ovn-bgp-agent.sh
  - frr-init.sh
  - frr-config-gen.sh
  - image-repo-sync.sh
权限: 0555 (可执行)
行为: 每次 helm upgrade 都会更新
```

#### configmap-etc (配置 ConfigMap)

```yaml
名称: ovn-bgp-agent-etc
内容:
  - ovn-bgp-agent.conf (Agent 配置)
  - rootwrap.conf (权限配置)
  - filters.conf (命令过滤器)
权限: 0444 (只读)
行为: 每次 helm upgrade 都会更新
```

#### configmap-asn (ASN 映射 ConfigMap)

```yaml
名称: ovn-bgp-agent-asn
内容:
  - mapping.json (Leaf ASN 映射)
权限: 0444 (只读)
行为: 
  - 首次安装: 从 values.yaml 创建
  - 后续 upgrade: 不修改(使用 lookup 函数检测)
  - 运行时: 可手动编辑
  - 卸载: 自动删除
特殊性: 这是运维数据,不应频繁变更
```

## 五、网络架构

### 典型 Leaf-Spine 拓扑

```
                    [Spine]
                  AS 65000 (iBGP between Spines)
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
```

### BGP 会话类型

| 会话类型 | 本端 | 对端 | Address Family | 用途 |
|---------|------|------|----------------|------|
| Server-Leaf | Server | Leaf | IPv4 Unicast | 路由通告 |
| Server-Spine | Server | Spine | L2VPN EVPN | VXLAN 路由(可选) |
| Leaf-Spine | Leaf | Spine | IPv4 + EVPN | 汇聚层 |

### ASN 分配策略

| 组件 | ASN 范围 | 分配方式 | 示例 |
|------|---------|---------|------|
| Server | 4200000000 - 4294967295 | 基于 IP 自动生成 | AS 4200049263 |
| Leaf | 65001 - 65534 | 手动规划(ConfigMap) | AS 65001 |
| Spine | 64512 - 65534 | 手动规划 | AS 65000 |

## 六、部署模式

### 1. 集中式部署 (Centralized)

**适用场景**: 租户网络通过网关端口暴露

```yaml
labels:
  agent:
    node_selector_key: openstack-network-node
    node_selector_value: enabled
```

**特点**:
- 部署在网络节点(运行 OVN Gateway)
- 流量路径: VM → OVN Gateway → BGP → Leaf
- 使用 `nb_ovn_bgp_driver`
- 需要配置 `expose_tenant_networks: true`

**流量示例**:
```
VM (172.16.1.10)
    ↓
OVN Distributed Router (cr-lrp)
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
```

**特点**:
- 部署在所有计算节点
- 流量路径: VM → Compute Node → BGP → Leaf
- 直接通告 VM IP
- 无需通过网关节点

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
               # "" 或 "detection" - 自动发现(推荐)
               # "first" - 子网第一个 IP
               # "last" - 子网最后一个 IP
               # "10.0.192.1" - 固定 IP
  
  # Leaf ASN 映射(仅首次安装使用)
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
      # 可选 driver:
      # - ovn_bgp_driver: 传统 SB DB driver
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
        memory: "256Mi"
        cpu: "200m"
      limits:
        memory: "1Gi"
        cpu: "1000m"
    frr:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "500m"
```

## 八、部署流程

### 标准部署步骤

```bash
# 1. 标记节点
kubectl label nodes worker1 openstack-network-node=enabled

# 2. 配置 Leaf ASN 映射(在 values.yaml 中)
cat > custom-values.yaml <<EOF
bgp:
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
# 添加新的 Rack/Leaf 映射
kubectl -n openstack edit configmap ovn-bgp-agent-asn

# 添加:
# "10.0.194.0/24": "65003"

# 新启动的 Pod 会使用新配置
# 已运行的 Pod 需要重启才能生效(可选)
kubectl -n openstack rollout restart daemonset ovn-bgp-agent
```

## 九、监控和故障排查

### 检查点清单

| 检查项 | 命令 | 预期结果 |
|-------|------|---------|
| Pod 状态 | `kubectl get pods` | Running |
| Init 容器日志 | `kubectl logs -c init-frr-config` | BGP Configuration 输出 |
| FRR 状态 | `vtysh -c "show bgp summary"` | Established |
| Agent 日志 | `kubectl logs -c ovn-bgp-agent` | No errors |
| 路由通告 | `vtysh -c "show ip bgp"` | 有路由条目 |

### 常见问题

#### 1. BGP 会话未建立

**症状**: `show bgp summary` 显示 `Idle` 或 `Active`

**排查**:
```bash
# 检查 Leaf 连通性
kubectl exec -c ovn-bgp-agent -- ping -c 3 10.0.192.1

# 检查 ASN 配置
kubectl exec -c init-frr-config -- cat /etc/frr/frr.conf | grep "remote-as"

# 检查 ConfigMap
kubectl get configmap ovn-bgp-agent-asn -o jsonpath='{.data.mapping\.json}'
```

**可能原因**:
- Leaf IP 不可达
- ASN 配置错误
- Leaf 侧未配置对等

#### 2. ConfigMap 中找不到 ASN 映射

**症状**: Init 容器失败,日志显示 "No Leaf ASN mapping found"

**排查**:
```bash
# 检查节点子网
kubectl exec -c init-frr-config -- ip route show dev br-ex

# 检查 ConfigMap 映射
kubectl get configmap ovn-bgp-agent-asn -o yaml

# 手动添加映射
kubectl edit configmap ovn-bgp-agent-asn
```

#### 3. Agent 无法连接 OVN 数据库

**症状**: Agent 容器 CrashLoopBackOff

**排查**:
```bash
# 测试 OVN NB 连接
kubectl exec -c ovn-bgp-agent -- \
  ovn-nbctl --db=tcp:ovn-ovsdb-nb:6641 show

# 检查 Service
kubectl get svc ovn-ovsdb-nb

# 检查网络策略
kubectl get networkpolicy
```

## 十、性能指标

### 资源使用建议

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
| 完全收敛(5000+ 路由) | <2min |

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
| FRR Socket | /run/frr/vtysh.sock | 读写 | 控制 FRR |

### Pod Security Standards

```yaml
# 最低要求: Restricted (不兼容)
# 推荐: Baseline
# 实际: Privileged (由于需要 NET_ADMIN)
```

## 十二、扩展和定制

### 支持的定制点

1. **自定义 Driver**: 通过 `conf.ovn_bgp_agent.DEFAULT.driver`
2. **自定义 Rootwrap 过滤器**: 通过 `conf.rootwrap.filters`
3. **额外的 Volume 挂载**: 通过 `pod.mounts`
4. **自定义资源限制**: 通过 `pod.resources`
5. **自定义容忍度**: 通过 `pod.tolerations`

### 示例: 添加自定义命令过滤器

```yaml
conf:
  rootwrap:
    filters: |
      [Filters]
      # 默认过滤器
      ip: CommandFilter, ip, root
      
      # 自定义过滤器
      my-script: CommandFilter, /usr/local/bin/my-script, root
```

## 十三、项目提交清单

### 镜像仓库提交 (openstack-helm-images)

- [ ] `ovn-bgp-agent/Dockerfile.ubuntu_noble`
- [ ] `ovn-bgp-agent/Dockerfile.ubuntu_jammy`
- [ ] `ovn-bgp-agent/build.sh`
- [ ] `ovn-bgp-agent/README.rst`
- [ ] `.zuul.yaml` (添加 CI jobs)
- [ ] 向 Kolla 注册 UID 42494

### Chart 仓库提交 (openstack-helm)

#### 核心文件
- [ ] `ovn-bgp-agent/Chart.yaml`
- [ ] `ovn-bgp-agent/values.yaml`
- [ ] `ovn-bgp-agent/README.md`
- [ ] `ovn-bgp-agent/NOTES.txt`
- [ ] `ovn-bgp-agent/STRUCTURE.md`

#### 模板文件
- [ ] `ovn-bgp-agent/templates/bin/_ovn-bgp-agent.sh.tpl`
- [ ] `ovn-bgp-agent/templates/bin/_frr-init.sh.tpl`
- [ ] `ovn-bgp-agent/templates/bin/_frr-config-gen.sh.tpl`
- [ ] `ovn-bgp-agent/templates/bin/_image-repo-sync.sh.tpl`
- [ ] `ovn-bgp-agent/templates/configmap-bin.yaml`
- [ ] `ovn-bgp-agent/templates/configmap-etc.yaml`
- [ ] `ovn-bgp-agent/templates/configmap-asn.yaml`
- [ ] `ovn-bgp-agent/templates/serviceaccount.yaml`
- [ ] `ovn-bgp-agent/templates/daemonset-ovn-bgp-agent.yaml`
- [ ] `ovn-bgp-agent/templates/poddisruptionbudget.yaml`
- [ ] `ovn-bgp-agent/templates/job-image-repo-sync.yaml`

#### 示例文件
- [ ] `ovn-bgp-agent/examples/configmap-asn-example.yaml`
- [ ] `ovn-bgp-agent/values_overrides/example.yaml`
- [ ] `ovn-bgp-agent/values_overrides/evpn.yaml`
- [ ] `ovn-bgp-agent/values_overrides/production.yaml`

## 十四、关键创新点

1. **零配置部署**
    - Server ASN 基于 IP 自动生成
    - Leaf 网关 IP 自动发现
    - 无需手动规划 Server ASN

2. **智能 ConfigMap 管理**
    - 首次安装创建,后续不覆盖
    - 支持运行时编辑
    - 卸载时自动清理

3. **模块化脚本设计**
    - 职责清晰的初始化脚本
    - 可复用的配置生成逻辑
    - 易于测试和调试

4. **灵活的部署模式**
    - 支持集中式/分布式/混合部署
    - 通过 node selector 灵活调度
    - 适应不同网络架构

5. **完善的故障排查**
    - 详细的初始化日志
    - 清晰的错误提示
    - 便捷的验证命令

## 十五、后续改进方向

### 短期 (3-6 个月)

- [ ] 添加 Prometheus Metrics 导出
- [ ] 支持 BFD 快速故障检测
- [ ] 支持 BGP Graceful Restart
- [ ] 添加 Grafana Dashboard

### 中期 (6-12 个月)

- [ ] 支持 IPv6 Only 环境
- [ ] 支持 Route Aggregation
- [ ] 支持多 Leaf 的 ECMP
- [ ] 集成 OpenStack-Helm CI/CD

### 长期 (12+ 个月)

- [ ] 支持 BGP Route Policy
- [ ] 支持 BGP Communities
- [ ] 自动化网络拓扑发现
- [ ] 集成 NetBox/IPAM 系统

## 十六、参考资源

### 官方文档
- **OVN BGP Agent**: https://docs.openstack.org/ovn-bgp-agent/latest/
- **OpenStack Helm**: https://docs.openstack.org/openstack-helm/latest/
- **FRRouting**: https://docs.frrouting.org/
- **Helm**: https://helm.sh/docs/

### RFC 标准
- **BGP-4**: RFC 4271
- **BGP Best Practices**: RFC 7938
- **EVPN**: RFC 7432, RFC 8365
- **BGP Graceful Restart**: RFC 4724

### 社区资源
- **OpenStack Discuss**: https://lists.openstack.org/mailman3/lists/openstack-discuss.lists.openstack.org/
- **Kolla UID Registry**: https://github.com/openstack/kolla/blob/master/kolla/common/users.py
- **OpenStack Helm GitHub**: https://github.com/openstack/openstack-helm

## 十七、贡献指南

### 提交 Patch

1. Fork 相应的仓库
2. 创建功能分支: `git checkout -b feature/my-feature`
3. 提交更改: `git commit -s -m "Add feature"`
4. 推送到 Gerrit: `git review`

### 测试要求

- 所有 Shell 脚本通过 ShellCheck
- Helm Chart 通过 `helm lint`
- 提供测试用例和文档
- 遵循 OpenStack Helm 编码规范

### 文档要求

- 更新 README.md
- 更新 STRUCTURE.md (如有架构变更)
- 提供 values 示例
- 添加故障排查指南

---

**版本**: 1.0  
**最后更新**: 2025-01-08  
**维护者**: OpenStack Helm Team