# Nexus - OpenStack API 透明代理服务

Nexus是OpenStack-Helm项目的一个子项目，提供OpenStack API的透明代理服务。它通过动态服务发现自动配置Nginx和DNSMasq，为非Kubernetes环境中的客户端提供访问OpenStack服务的能力。

## 🎯 核心功能

- **动态服务发现**: 自动发现OpenStack命名空间中的所有服务
- **透明代理**: 通过LoadBalancer提供统一的API入口
- **DNS解析**: 提供DNS代理服务，解析OpenStack服务域名
- **热更新**: 无需重启即可更新代理配置
- **高可用**: 支持多副本部署和负载均衡
- **SSL支持**: 自动生成SSL证书或使用自定义证书
- **配置持久化**: 使用PVC进行配置共享和持久化

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

## 📁 项目文件结构

### 目录布局

```
nexus/
├── Chart.yaml                           # Helm Chart 元数据
├── values.yaml                          # 默认配置文件
├── README.md                            # 项目说明文档
├── Example.md                           # 部署示例和最佳实践
├── templates/                           # Kubernetes 资源模板目录
│   ├── certificates.yaml               # TLS 证书配置
│   ├── configmap-bin.yaml              # Shell 脚本配置映射  
│   ├── configmap-etc.yaml              # 配置文件映射
│   ├── deployment-proxy.yaml           # Nginx 代理部署
│   ├── deployment-dns.yaml             # DNSMasq DNS 部署
│   ├── job-image-repo-sync.yaml        # 镜像同步任务
│   ├── network-policy.yaml             # 网络策略
│   ├── pvc-shared-config.yaml          # 共享配置存储
│   ├── secret-keystone.yaml            # OpenStack 认证密钥
│   ├── secret-registry.yaml            # 镜像仓库密钥
│   ├── discovery.yaml          # 服务发现 CronJob
│   ├── service-dns.yaml                # DNS 服务
│   ├── service-proxy.yaml              # 代理服务
│   └── service-rbac.yaml               # RBAC 权限配置
└── bin/                                 # Shell 脚本目录
    ├── _init-config.sh.tpl             # 配置初始化脚本
    ├── _service-discover.sh.tpl        # 服务发现脚本
    ├── _gen-nginx-config.sh.tpl        # Nginx 配置生成
    ├── _gen-dns-config.sh.tpl          # DNS 配置生成  
    ├── _config-manager.sh.tpl          # 配置管理脚本
    ├── _orchestrator.sh.tpl            # 服务发现编排
    ├── _proxy-start.sh.tpl             # Nginx 启动脚本
    ├── _dns-start.sh.tpl               # DNSMasq 启动脚本
    └── _keystone-auth.sh.tpl           # OpenStack 认证脚本
```

### 核心文件说明

#### 配置文件
- **Chart.yaml**: Helm Chart 基本信息和依赖
- **values.yaml**: 包含所有可配置参数的默认值
- **README.md**: 项目介绍、安装和使用文档
- **Example.md**: 详细的部署示例和故障排除

#### Kubernetes 资源模板
- **部署相关**: deployment-proxy.yaml, deployment-dns.yaml
- **服务相关**: service-proxy.yaml, service-dns.yaml, discovery.yaml
- **配置相关**: configmap-bin.yaml, configmap-etc.yaml, pvc-shared-config.yaml
- **安全相关**: secret-keystone.yaml, service-rbac.yaml, network-policy.yaml
- **任务相关**: job-image-repo-sync.yaml

#### Shell 脚本组件
- **初始化**: _init-config.sh.tpl - 容器启动时配置初始化
- **服务发现**: _service-discover.sh.tpl - K8s 服务发现
- **配置生成**: _gen-nginx-config.sh.tpl, _gen-dns-config.sh.tpl
- **配置管理**: _config-manager.sh.tpl - 原子性配置更新
- **服务启动**: _proxy-start.sh.tpl, _dns-start.sh.tpl - 服务启动和监控
- **编排协调**: _orchestrator.sh.tpl - 整体流程编排
- **认证集成**: _keystone-auth.sh.tpl - OpenStack 认证支持

### 工作流程

1. **初始化阶段**
    - `_init-config.sh.tpl` 在 initContainer 中运行
    - 复制初始配置到共享存储 (PVC)
    - 确保服务能够正常启动

2. **服务启动阶段**
    - `_proxy-start.sh.tpl` 启动 Nginx 并监控配置变化
    - `_dns-start.sh.tpl` 启动 DNSMasq 并监控配置变化
    - 两个服务都从共享存储读取配置

3. **服务发现阶段**
    - CronJob 定期运行 `_orchestrator.sh.tpl`
    - 调用 `_service-discover.sh.tpl` 发现 OpenStack 服务
    - 调用配置生成脚本创建新配置
    - 通过 `_config-manager.sh.tpl` 原子性更新配置

4. **热更新阶段**
    - 配置文件变更时发送重载信号
    - Nginx 和 DNSMasq 无缝重载新配置
    - 保持服务连续性

### 特性亮点

#### 模块化设计
- 每个 Shell 脚本职责单一，便于维护和测试
- 使用共享存储实现配置同步
- 支持配置热更新，无需重启服务

#### 高可用支持
- 多副本部署支持
- 健康检查和自动恢复
- 优雅的服务重启机制

#### 生产就绪
- 完整的错误处理和日志记录
- 配置验证和原子性更新
- 符合 OpenStack-Helm 标准规范

#### 安全性
- RBAC 权限控制
- 网络策略支持
- OpenStack 认证集成

## 🚀 快速开始

### 前置条件

- Kubernetes集群 (1.19+)
- Helm 3.x
- helm-toolkit (OpenStack-Helm依赖)
- 支持ReadWriteMany的存储类 (如NFS, CephFS)
- LoadBalancer控制器 (如MetalLB)

### 基本安装

```bash
# 添加OpenStack-Helm仓库
helm repo add openstack-helm https://openstack.github.io/openstack-helm/

# 安装helm-toolkit
helm install helm-toolkit openstack-helm/helm-toolkit

# 克隆并安装Nexus
git clone https://github.com/openstack/openstack-helm
cd openstack-helm/nexus

# 基本安装
helm install nexus . -n openstack-proxy --create-namespace
```

### 自定义配置

```bash
# 创建自定义values文件
cat > custom-values.yaml << EOF
# LoadBalancer固定IP
proxy:
  loadbalancer_ip: "192.168.1.100"
  ssl:
    enabled: true

dns:
  enabled: true
  loadbalancer_ip: "192.168.1.101"

# OpenStack配置
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

## 📋 配置参考

### 主要配置选项

| 配置项 | 描述 | 默认值 |
|--------|------|--------|
| `discovery.enabled` | 启用服务发现 | `true` |
| `discovery.interval` | 发现间隔(分钟) | `5` |
| `discovery.openstack_namespace` | OpenStack命名空间 | `openstack` |
| `proxy.service_type` | 代理服务类型 | `LoadBalancer` |
| `proxy.ssl.enabled` | 启用SSL | `true` |
| `dns.enabled` | 启用DNS代理 | `true` |
| `storage.shared_config.class` | 存储类 | `general-fs` |

### 完整配置示例

参考 `values.yaml` 文件中的详细配置选项。

## 🔧 使用场景

### 场景1: 基础HTTP代理

```bash
helm install nexus . \
  --set proxy.ssl.enabled=false \
  --set dns.enabled=false \
  -n openstack-proxy --create-namespace
```

### 场景2: 完整的API网关

```bash
helm install nexus . \
  --set proxy.loadbalancer_ip="192.168.1.100" \
  --set dns.loadbalancer_ip="192.168.1.101" \
  --set proxy.ssl.enabled=true \
  --set dns.enabled=true \
  -n openstack-proxy --create-namespace
```

### 场景3: 开发环境快速部署

```bash
helm install nexus . \
  --set storage.shared_config.class="hostpath" \
  --set pod.replicas.proxy=1 \
  --set pod.replicas.dns=1 \
  -n openstack-proxy --create-namespace
```

## 🔍 运维管理

### 监控服务状态

```bash
# 查看Pod状态
kubectl get pods -n openstack-proxy

# 查看服务状态
kubectl get svc -n openstack-proxy

# 查看CronJob状态
kubectl get cronjob -n openstack-proxy
```

### 查看日志

```bash
# 代理服务日志
kubectl logs -f deployment/nexus-proxy -n openstack-proxy

# DNS服务日志
kubectl logs -f deployment/nexus-dns -n openstack-proxy

# 服务发现日志
kubectl logs -l app=nexus,component=discovery -n openstack-proxy
```

### 手动触发服务发现

```bash
# 创建手动Job
kubectl create job --from=cronjob/nexus-discovery nexus-discovery-manual -n openstack-proxy

# 查看执行结果
kubectl logs job/nexus-discovery-manual -n openstack-proxy
```

### 配置更新

```bash
# 更新配置
helm upgrade nexus . -f custom-values.yaml -n openstack-proxy

# 重启特定组件
kubectl rollout restart deployment/nexus-proxy -n openstack-proxy
kubectl rollout restart deployment/nexus-dns -n openstack-proxy
```

### 扩容/缩容

```bash
# 扩容代理服务
kubectl scale deployment nexus-proxy --replicas=5 -n openstack-proxy

# 扩容DNS服务
kubectl scale deployment nexus-dns --replicas=3 -n openstack-proxy

# 或者通过Helm更新
helm upgrade nexus . \
  --set pod.replicas.proxy=5 \
  --set pod.replicas.dns=3 \
  --reuse-values \
  -n openstack-proxy
```

### 备份和恢复

```bash
# 备份配置
kubectl get pvc nexus-shared-config -n openstack-proxy -o yaml > nexus-pvc-backup.yaml
kubectl cp nexus-proxy-xxx:/shared/config ./config-backup -n openstack-proxy

# 恢复配置
kubectl apply -f nexus-pvc-backup.yaml
kubectl cp ./config-backup nexus-proxy-xxx:/shared/config -n openstack-proxy
```

## 🐛 故障排除

### 常见问题

#### 1. LoadBalancer IP一直Pending

```bash
# 检查LoadBalancer控制器
kubectl get pods -n metallb-system
kubectl logs -f deployment/controller -n metallb-system

# 检查IP池配置
kubectl get ipaddresspool -n metallb-system
kubectl describe ipaddresspool -n metallb-system

# 临时使用NodePort
helm upgrade nexus . \
  --set proxy.service_type=NodePort \
  --set dns.service_type=NodePort \
  --reuse-values \
  -n openstack-proxy
```

#### 2. 服务发现失败

```bash
# 检查RBAC权限
kubectl auth can-i get services --as=system:serviceaccount:openstack-proxy:nexus-discovery -n openstack
kubectl auth can-i list services --as=system:serviceaccount:openstack-proxy:nexus-discovery -n openstack

# 检查OpenStack命名空间
kubectl get ns openstack
kubectl get svc -n openstack

# 手动测试服务发现
kubectl run debug --image=quay.io/airshipit/kubernetes-entrypoint:v1.0.0 --rm -it -- /bin/bash
kubectl -n openstack get svc -o json
```

#### 3. 配置更新不生效

```bash
# 检查PVC状态
kubectl get pvc -n openstack-proxy
kubectl describe pvc nexus-shared-config -n openstack-proxy

# 检查共享存储
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- ls -la /shared/config/
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- cat /shared/config/nginx/default.conf

# 强制重新生成配置
kubectl delete job -l app=nexus,component=discovery -n openstack-proxy
kubectl create job --from=cronjob/nexus-discovery nexus-discovery-force -n openstack-proxy
```

#### 4. SSL证书问题

```bash
# 检查证书
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- ls -la /etc/nginx/ssl/
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- openssl x509 -in /etc/nginx/ssl/tls.crt -text -noout

# 重新生成证书
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- rm -f /etc/nginx/ssl/*
kubectl rollout restart deployment/nexus-proxy -n openstack-proxy
```

### 调试命令

```bash
# 检查共享配置
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- ls -la /shared/config/

# 测试DNS解析
kubectl exec -it deployment/nexus-dns -n openstack-proxy -- nslookup keystone.openstack.svc.cluster.local localhost

# 检查配置文件
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- cat /etc/nginx/conf.d/default.conf
```

## 🔄 升级和维护

```bash
# 升级Chart
helm upgrade nexus . -f custom-values.yaml -n openstack-proxy

# 重启服务
kubectl rollout restart deployment/nexus-proxy -n openstack-proxy
kubectl rollout restart deployment/nexus-dns -n openstack-proxy

# 强制重新发现服务
kubectl delete job -l app=nexus,component=discovery -n openstack-proxy
```

## 📚 开发和贡献

### 脚本架构

- **模块化设计**: 每个脚本职责单一，便于测试和维护
- **错误处理**: 完善的错误处理和日志记录
- **配置验证**: 配置文件语法验证和原子性更新
- **信号处理**: 优雅的服务重启和配置重载

### 贡献指南

1. Fork项目并创建特性分支
2. 遵循Shell脚本最佳实践
3. 添加适当的测试和文档
4. 提交Pull Request

## 📝 许可证

本项目遵循Apache License 2.0许可证。