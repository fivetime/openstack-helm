# OVN BGP Agent 项目结构总结

本文档总结了OVN BGP Agent镜像和Helm Chart的完整项目结构。

## 一、镜像项目结构 (openstack-helm-images)

提交到: https://github.com/openstack/openstack-helm-images

```
openstack-helm-images/
└── ovn-bgp-agent/
    ├── Dockerfile.ubuntu_noble       # Ubuntu 24.04 镜像
    ├── Dockerfile.ubuntu_jammy       # Ubuntu 22.04 镜像
    ├── build.sh                      # 镜像构建脚本
    └── README.rst                    # 镜像文档
```

### 镜像关键特性

**设计原则:**
- ✅ 最小化: 只包含 Python 运行环境和 ovn-bgp-agent
- ✅ 安全性: 非 root 用户运行 (UID 42494)
- ✅ 标准化: 遵循 OpenStack-Helm 镜像规范
- ✅ 独立身份: 加入 openvswitch 组 (GID 42424) 访问 OVS socket

**UID/GID 分配:**
```
UID 42494: ovn-bgp-agent user (需向 Kolla 注册)
GID 42494: ovn-bgp-agent group (主组)
GID 42424: openvswitch group (补充组,用于访问 OVS socket)
```

**不包含的组件:**
- OVS/OVN 工具 - 假设已在宿主机/其他容器部署
- FRR - 作为 sidecar 容器单独部署

## 二、Helm Chart项目结构 (openstack-helm)

提交到: https://github.com/openstack/openstack-helm

```
openstack-helm/
└── ovn-bgp-agent/
    ├── Chart.yaml                              # Chart 元数据
    ├── values.yaml                            # 默认配置
    ├── README.md                              # 使用文档
    ├── STRUCTURE.md                           # 本文档
    │
    ├── templates/
    │   ├── bin/
    │   │   ├── _ovn-bgp-agent.sh.tpl         # Agent 启动脚本
    │   │   ├── _frr-init.sh.tpl              # FRR 初始化(网关发现)
    │   │   └── _frr-config-gen.sh.tpl        # FRR 配置生成
    │   │
    │   ├── configmap-bin.yaml                # 脚本 ConfigMap
    │   ├── secret-etc.yaml                   # 配置 Secret
    │   ├── serviceaccount.yaml               # RBAC 配置
    │   ├── daemonset.yaml                    # DaemonSet 定义
    │   ├── poddisruptionbudget.yaml          # PDB
    │   └── job-image-repo-sync.yaml          # 镜像同步
    │
    └── values_overrides/
        ├── example.yaml                       # 基础示例
        ├── evpn.yaml                          # EVPN 配置示例
        └── production.yaml                    # 生产配置示例
```

## 三、核心设计

### 1. 智能 BGP 配置

#### ASN 自动生成策略

```python
# 基于 IP 的确定性 ASN 生成
ASN = 4200000000 + (octet2 * 65536) + (octet3 * 256) + octet4

示例:
Server:  10.0.192.111 → AS 4200049263
Leaf:    10.0.192.1   → AS 4200049153
```

优点:
- 无需手动分配
- 重启后 ASN 保持不变
- 不同 IP 不会冲突
- 适用于分布式部署

#### 网关自动发现

三级 Fallback 机制:
```
1. 路由表: ip route show dev br-ex | grep default
   ↓ (失败)
2. ARP 扫描: ping first/last IP → 检查 ARP 表
   ↓ (失败)
3. 子网约定: 使用 network + 1 (通常是 .1)
```

### 2. 模块化脚本设计

```
_frr-init.sh.tpl
    ├─→ 网关发现逻辑
    ├─→ ASN 计算
    ├─→ 连通性验证
    └─→ 调用 _frr-config-gen.sh.tpl

_frr-config-gen.sh.tpl
    ├─→ 生成 daemons 文件
    ├─→ 生成 frr.conf
    │   ├─→ BGP 基础配置
    │   ├─→ IPv4 Unicast (to Leaf)
    │   └─→ L2VPN EVPN (to RR, 可选)
    └─→ 设置文件权限
```

### 3. 部署模式

#### 集中式部署 (Centralized)

```yaml
labels:
  agent:
    node_selector_key: openstack-network-node
    node_selector_value: enabled
```

- 部署在网络节点
- 用于租户网络暴露
- 流量通过 OVN 网关端口

#### 分布式部署 (Distributed)

```yaml
labels:
  agent:
    node_selector_key: openstack-compute-node
    node_selector_value: enabled
```

- 部署在所有计算节点
- 用于 Provider 网络和 FIP
- 流量直接从 VM 所在节点出去

## 四、配置详解

### values.yaml 核心配置

```yaml
# BGP 基础配置
bgp:
  enabled: true
  
  # Peer IP 发现模式
  peer_ip: ""              # 空或"detection"=自动,"first","last",或固定IP
  peer_asn: ""             # 空=基于 peer_ip 计算
  
  # EVPN 配置
  evpn:
    enabled: false
    rr_ip: ""              # Route Reflector IP (Spine loopback)
    rr_asn: ""             # RR ASN (16-bit private: 64512-65534)

# Driver 选择
conf:
  ovn_bgp_agent:
    DEFAULT:
      driver: nb_ovn_bgp_driver           # 推荐
      expose_tenant_networks: false
      address_scopes: ""
```

### 支持的 Driver

| Driver | 数据库 | 用途 | 稳定性 |
|--------|--------|------|--------|
| `nb_ovn_bgp_driver` | OVN NB | 推荐使用 | ★★★★★ |
| `ovn_bgp_driver` | OVN SB | 传统方式 | ★★★★☆ |
| `ovn_evpn_driver` | OVN SB | EVPN 支持 | ★★★☆☆ |
| `ovn_stretched_l2_bgp_driver` | OVN SB | L2 扩展 | ★★★☆☆ |

## 五、网络架构

### Leaf-Spine 拓扑

```
                 [Spine]
              AS 65000 (16-bit)
                    |
         +----------+----------+
         |                     |
     [Leaf-1]              [Leaf-2]
  AS 4200049153         AS 4200049409 (32-bit)
  10.0.192.1            10.0.193.1
         |                     |
    [Server-1]            [Server-2]
  AS 4200049263         AS 4200049469 (32-bit)
  10.0.192.111          10.0.193.111
```

### BGP 会话关系

```
Server ←eBGP→ Leaf:  IPv4 Unicast
Server ←iBGP→ Spine: L2VPN EVPN (可选)
Leaf ←eBGP→ Spine:   IPv4 + EVPN
```

## 六、部署流程

### 快速部署

```bash
# 1. 标记节点
kubectl label nodes worker1 openstack-network-node=enabled

# 2. 安装 Chart (零配置)
helm install ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack \
  --create-namespace

# 3. 验证
kubectl -n openstack get pods -l application=ovn-bgp-agent
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp summary"
```

### 带 EVPN 的部署

```bash
helm install ovn-bgp-agent ./ovn-bgp-agent \
  --namespace openstack \
  --set bgp.peer_ip="10.0.192.1" \
  --set bgp.evpn.enabled=true \
  --set bgp.evpn.rr_ip="192.168.100.1" \
  --set bgp.evpn.rr_asn="65000"
```

## 七、故障排查

### 常见问题

#### 1. BGP 会话未建立

```bash
# 检查配置
kubectl -n openstack logs daemonset/ovn-bgp-agent -c ovn-bgp-agent | grep "BGP Configuration"

# 检查连通性
kubectl -n openstack exec daemonset/ovn-bgp-agent -c ovn-bgp-agent -- \
  ping -c 3 10.0.192.1

# 检查 FRR 状态
kubectl -n openstack exec daemonset/ovn-bgp-agent -c frr -- \
  vtysh -c "show bgp neighbors"
```

#### 2. 错误的 Peer IP

```bash
# 查看发现的 IP
kubectl -n openstack logs daemonset/ovn-bgp-agent -c ovn-bgp-agent | grep "Peer (Leaf"

# 手动指定
helm upgrade ovn-bgp-agent ./ovn-bgp-agent \
  --set bgp.peer_ip="10.0.192.1" \
  --reuse-values
```

#### 3. Agent 无法访问 OVN

```bash
# 测试 OVN 连接
kubectl -n openstack exec daemonset/ovn-bgp-agent -c ovn-bgp-agent -- \
  curl -v tcp://ovn-ovsdb-nb:6641
```

## 八、提交清单

### 镜像仓库 (openstack-helm-images)

- [ ] `ovn-bgp-agent/Dockerfile.ubuntu_noble`
- [ ] `ovn-bgp-agent/Dockerfile.ubuntu_jammy`
- [ ] `ovn-bgp-agent/build.sh`
- [ ] `ovn-bgp-agent/README.rst`
- [ ] `.zuul.yaml` (添加 CI jobs)

### Chart 仓库 (openstack-helm)

- [ ] `ovn-bgp-agent/Chart.yaml`
- [ ] `ovn-bgp-agent/values.yaml`
- [ ] `ovn-bgp-agent/README.md`
- [ ] `ovn-bgp-agent/STRUCTURE.md`
- [ ] `ovn-bgp-agent/templates/bin/_ovn-bgp-agent.sh.tpl`
- [ ] `ovn-bgp-agent/templates/bin/_frr-init.sh.tpl`
- [ ] `ovn-bgp-agent/templates/bin/_frr-config-gen.sh.tpl`
- [ ] `ovn-bgp-agent/templates/configmap-bin.yaml`
- [ ] `ovn-bgp-agent/templates/secret-etc.yaml`
- [ ] `ovn-bgp-agent/templates/serviceaccount.yaml`
- [ ] `ovn-bgp-agent/templates/daemonset.yaml`
- [ ] `ovn-bgp-agent/templates/poddisruptionbudget.yaml`
- [ ] `ovn-bgp-agent/templates/job-image-repo-sync.yaml`
- [ ] `ovn-bgp-agent/values_overrides/example.yaml`
- [ ] `ovn-bgp-agent/values_overrides/evpn.yaml`
- [ ] `ovn-bgp-agent/values_overrides/production.yaml`

## 九、关键创新点

1. **零配置 BGP**: 基于 IP 的确定性 ASN,自动网关发现
2. **模块化设计**: 分离网关发现和配置生成逻辑
3. **多级 Fallback**: 路由表 → ARP → 子网约定
4. **EVPN 支持**: 同时支持 Leaf eBGP 和 Spine iBGP
5. **灵活部署**: 支持集中式、分布式、混合模式

## 十、性能指标

### 资源使用

| 规模 | Agent 内存 | FRR 内存 | Agent CPU | FRR CPU |
|------|-----------|----------|-----------|---------|
| 小 (<100 VMs) | 256Mi | 128Mi | 200m | 100m |
| 中 (100-500) | 512Mi | 256Mi | 500m | 200m |
| 大 (500-1000) | 1Gi | 512Mi | 1000m | 500m |
| 超大 (>1000) | 2Gi | 512Mi | 2000m | 500m |

### BGP 收敛时间

- 单个路由: <1s
- 100 路由: <5s
- 1000 路由: <30s

## 十一、安全考虑

### 必需的权限

```yaml
securityContext:
  privileged: true  # 或使用 capabilities
  capabilities:
    add:
      - NET_ADMIN   # 必需: kernel routing
      - SYS_ADMIN   # 可选: 网络命名空间
      - NET_RAW     # 可选: ARP 扫描
```

### 网络访问

- OVS socket: `/run/openvswitch/db.sock` (读取)
- OVN NB: `tcp://ovn-ovsdb-nb:6641` (读取)
- OVN SB: `tcp://ovn-ovsdb-sb:6642` (读取)
- FRR socket: `/run/frr/vtysh.sock` (读写)

## 十二、后续改进方向

- [ ] 支持 BFD (快速故障检测)
- [ ] 支持 BGP Graceful Restart
- [ ] 支持 Route Aggregation
- [ ] Prometheus Metrics 导出
- [ ] 支持 IPv6 Only 环境
- [ ] 支持多 Leaf 的 ECMP
- [ ] 集成 OpenStack-Helm CI/CD

## 十三、参考资源

- **OVN BGP Agent**: https://docs.openstack.org/ovn-bgp-agent/latest/
- **OpenStack Helm**: https://docs.openstack.org/openstack-helm/latest/
- **FRRouting**: https://docs.frrouting.org/
- **BGP RFC**: RFC 4271, RFC 7938
- **EVPN RFC**: RFC 7432, RFC 8365
- **Kolla UID Registry**: https://github.com/openstack/kolla/blob/master/kolla/common/users.py