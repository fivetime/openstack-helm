# Nexus - OpenStack API 透明代理服务

Nexus 是 OpenStack-Helm 项目的一个子项目，提供 OpenStack API 的透明代理服务。它通过动态服务发现自动配置 Nginx 和 DNSMasq，为非 Kubernetes 环境中的客户端提供访问 OpenStack 服务的能力。

## 🎯 核心功能

- **动态服务发现**: 自动发现 OpenStack 命名空间中的所有服务
- **透明代理**: 通过 LoadBalancer 提供统一的 API 入口
- **DNS 解析**: 提供 DNS 代理服务，解析 OpenStack 服务域名
- **热更新**: 无需重启即可更新代理配置
- **高可用**: 支持多副本部署和负载均衡
- **SSL 支持**: 自动生成 SSL 证书或使用自定义证书
- **配置持久化**: 使用 PVC 进行配置共享和持久化

## 🏗️ 架构设计

```
┌─────────────────────────────────────────────────────────────────┐
│                    Nexus Architecture                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ DNS Service │    │Proxy Service│    │Service Discovery    │  │
│  │(DNSMasq)    │    │  (Nginx)    │    │     (CronJob)       │  │
│  │             │    │             │    │                     │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│         │                   │                        │          │
│         └───────────────────┼────────────────────────┘          │
│                            │                                   │
│                  ┌─────────────────┐                           │
│                  │ Shared Config   │                           │
│                  │     (PVC)       │                           │
│                  └─────────────────┘                           │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    外部访问                                      │
│  LoadBalancer IP:80/443 ←→ HTTP(S) Proxy                      │
│  LoadBalancer IP:53     ←→ DNS Proxy                          │
└─────────────────────────────────────────────────────────────────┘
```

## 📁 项目结构

```
nexus/
├── Chart.yaml                  # Helm Chart 元数据
├── values.yaml                 # 默认配置文件
├── README.md                   # 项目说明文档
├── Example.md                  # 部署示例和最佳实践
├── templates/                  # Kubernetes 资源模板
│   ├── configmap-bin.yaml     # Shell 脚本配置映射
│   ├── configmap-etc.yaml     # 配置文件映射
│   ├── deployment-proxy.yaml  # Nginx 代理部署
│   ├── deployment-dns.yaml    # DNSMasq DNS 部署
│   ├── service-proxy.yaml     # 代理服务
│   ├── service-dns.yaml       # DNS 服务
│   ├── service-discovery.yaml # 服务发现 CronJob
│   ├── pvc-shared-config.yaml # 共享配置存储
│   └── ...                    # 其他资源文件
└── bin/                        # Shell 脚本模板
    ├── _service-discover.sh.tpl
    ├── _gen-nginx-config.sh.tpl
    ├── _gen-dns-config.sh.tpl
    ├── _config-manager.sh.tpl
    ├── _orchestrator.sh.tpl
    └── _keystone-auth.sh.tpl
```

## 🚀 快速开始

### 前置条件

- Kubernetes 集群 (1.19+)
- Helm 3.x
- 支持 ReadWriteMany 的存储类 (如 NFS, CephFS)
- LoadBalancer 控制器 (如 MetalLB) 或 NodePort 访问

### 基本安装

```bash
# 克隆项目
git clone <your-repo-url>
cd nexus

# 基本安装
helm install nexus . -n openstack-proxy --create-namespace

# 查看部署状态
kubectl get pods -n openstack-proxy
kubectl get svc -n openstack-proxy
```

### 自定义配置

```bash
# 创建自定义 values 文件
cat > custom-values.yaml << EOF
# LoadBalancer 固定 IP
proxy:
  loadbalancer_ip: "192.168.1.100"
  ssl:
    enabled: true

dns:
  enabled: true
  loadbalancer_ip: "192.168.1.101"

# OpenStack 配置
discovery:
  openstack_namespace: "openstack"
  public_service_name: "public-openstack"
  fallback_target: "10.0.30.110"

# 高可用配置
pod:
  replicas:
    proxy: 3
    dns: 2

# 存储配置
storage:
  shared_config:
    class: "nfs-client"
    size: "2Gi"
EOF

# 使用自定义配置安装
helm install nexus . -f custom-values.yaml -n openstack-proxy --create-namespace
```

## 📋 主要配置选项

| 配置项 | 描述 | 默认值 |
|--------|------|--------|
| `discovery.enabled` | 启用服务发现 | `true` |
| `discovery.interval` | 发现间隔(分钟) | `5` |
| `discovery.openstack_namespace` | OpenStack 命名空间 | `openstack` |
| `proxy.service_type` | 代理服务类型 | `LoadBalancer` |
| `proxy.ssl.enabled` | 启用 SSL | `true` |
| `dns.enabled` | 启用 DNS 代理 | `true` |
| `storage.shared_config.class` | 存储类 | `general-fs` |

## 🔧 使用指南

### 获取服务地址

```bash
# 获取代理服务地址
PROXY_IP=$(kubectl get svc nexus-proxy -n openstack-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "代理服务: http://${PROXY_IP}"

# 获取 DNS 服务地址
DNS_IP=$(kubectl get svc nexus-dns -n openstack-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "DNS 服务: ${DNS_IP}:53"
```

### 配置客户端

#### OpenStack CLI 配置

```bash
# 创建 OpenStack 配置
cat > ~/.config/openstack/clouds.yaml << EOF
clouds:
  nexus-proxy:
    auth:
      auth_url: 'http://${PROXY_IP}/v3'
      username: 'admin'
      password: 'your-password'
      project_name: 'admin'
      project_domain_name: 'default'
      user_domain_name: 'default'
    region_name: RegionOne
EOF

# 使用配置
export OS_CLOUD=nexus-proxy
openstack server list
```

#### DNS 配置

```bash
# 配置系统 DNS
echo "nameserver ${DNS_IP}" | sudo tee /etc/resolv.conf

# 测试 DNS 解析
nslookup keystone.openstack.svc.cluster.local ${DNS_IP}
```

## 🔍 运维管理

### 监控服务状态

```bash
# 查看 Pod 状态
kubectl get pods -n openstack-proxy -w

# 查看日志
kubectl logs -f deployment/nexus-proxy -n openstack-proxy
kubectl logs -f deployment/nexus-dns -n openstack-proxy

# 查看服务发现日志
kubectl logs -l app=nexus,component=discovery -n openstack-proxy
```

### 手动触发服务发现

```bash
# 创建手动 Job
kubectl create job --from=cronjob/nexus-discovery manual-discovery -n openstack-proxy

# 查看执行结果
kubectl logs job/manual-discovery -n openstack-proxy
```

### 配置更新

```bash
# 更新配置
helm upgrade nexus . -f custom-values.yaml -n openstack-proxy

# 重启组件
kubectl rollout restart deployment/nexus-proxy -n openstack-proxy
kubectl rollout restart deployment/nexus-dns -n openstack-proxy
```

## 🐛 故障排除

### LoadBalancer IP Pending

如果 LoadBalancer IP 一直处于 Pending 状态：

```bash
# 改用 NodePort
helm upgrade nexus . \
  --set proxy.service_type=NodePort \
  --set dns.service_type=NodePort \
  --reuse-values \
  -n openstack-proxy
```

### 服务发现失败

```bash
# 检查 OpenStack 命名空间
kubectl get svc -n openstack

# 检查 RBAC 权限
kubectl auth can-i list services --as=system:serviceaccount:openstack-proxy:nexus-discovery -n openstack
```

### DNS 解析失败

```bash
# 检查 DNS 配置
kubectl exec -it deployment/nexus-dns -n openstack-proxy -- cat /etc/dnsmasq.conf

# 测试内部解析
kubectl exec -it deployment/nexus-dns -n openstack-proxy -- nslookup keystone.openstack localhost
```

## 📚 进阶配置

详细的部署示例、高级配置和最佳实践请参考 [Example.md](Example.md)。

## 📝 许可证

本项目遵循 Apache License 2.0 许可证。