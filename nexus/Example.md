# Nexus 部署示例和最佳实践

## 🚀 典型部署场景

### 1. 开发环境快速部署

最小化配置，适合开发和测试环境：

```bash
# dev-values.yaml
cat > dev-values.yaml << 'EOF'
# 开发环境 - 最小化配置
proxy:
  service_type: NodePort
  ssl:
    enabled: false

dns:
  enabled: false  # 开发环境可选

discovery:
  interval: 2  # 更频繁的发现
  fallback_target: "10.0.30.110"

pod:
  replicas:
    proxy: 1
    dns: 1

storage:
  shared_config:
    class: ""  # 使用默认存储类
    size: "500Mi"
EOF

# 部署
helm install nexus . -f dev-values.yaml -n openstack --create-namespace

# 获取 NodePort
kubectl get svc nexus-proxy -n openstack
```

### 2. 生产环境高可用部署

```bash
# prod-values.yaml
cat > prod-values.yaml << 'EOF'
# 生产环境配置
proxy:
  service_type: LoadBalancer
  loadbalancer_ip: "192.168.1.100"
  ssl:
    enabled: true
    auto_generate: true
  worker_processes: 4
  worker_connections: 2048

dns:
  enabled: true
  service_type: LoadBalancer
  loadbalancer_ip: "192.168.1.101"
  upstream_dns:
    - "8.8.8.8"
    - "8.8.4.4"

discovery:
  interval: 5
  openstack_namespace: "openstack"
  public_service_name: "public-openstack"

pod:
  replicas:
    proxy: 3
    dns: 2
  resources:
    enabled: true
    proxy:
      requests:
        memory: "512Mi"
        cpu: "500m"
      limits:
        memory: "2Gi"
        cpu: "2000m"

storage:
  shared_config:
    size: "2Gi"
    class: "cephfs"  # 使用分布式存储
EOF

helm install nexus . -f prod-values.yaml -n openstack-proxy --create-namespace
```

### 3. 仅代理模式（无 DNS）

```bash
# proxy-only-values.yaml
cat > proxy-only-values.yaml << 'EOF'
dns:
  enabled: false

proxy:
  service_type: LoadBalancer
  ssl:
    enabled: true

discovery:
  enabled: true
  openstack_namespace: "openstack"
EOF

helm install nexus . -f proxy-only-values.yaml -n openstack-proxy --create-namespace
```

## 🔧 配置实例

### 使用现有 SSL 证书

```bash
# 创建证书 Secret
kubectl create secret tls nexus-tls \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n openstack-proxy

# ssl-values.yaml
cat > ssl-values.yaml << 'EOF'
proxy:
  ssl:
    enabled: true
    auto_generate: false
    secret_name: "nexus-tls"
EOF

helm install nexus . -f ssl-values.yaml -n openstack-proxy
```

### 自定义上游 DNS

```bash
# custom-dns-values.yaml
cat > custom-dns-values.yaml << 'EOF'
dns:
  enabled: true
  upstream_dns:
    - "10.0.0.1"     # 内部 DNS
    - "10.0.0.2"     # 备用内部 DNS
    - "8.8.8.8"      # 公共 DNS 备份
  
  # 自定义转发区域
  forward_zones:
    - zone: "internal.company.com"
      servers: ["10.0.0.1", "10.0.0.2"]
EOF

helm install nexus . -f custom-dns-values.yaml -n openstack-proxy
```

### 使用特定存储类

```bash
# storage-values.yaml
cat > storage-values.yaml << 'EOF'
storage:
  shared_config:
    enabled: true
    size: "5Gi"
    class: "nfs-client"
    # 或者使用选择器
    selector:
      matchLabels:
        type: "nexus-config"
EOF

helm install nexus . -f storage-values.yaml -n openstack-proxy
```

## 📊 客户端配置示例

### OpenStack CLI 配置

```bash
# 获取代理地址
PROXY_IP=$(kubectl get svc nexus-proxy -n openstack-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 方式1: 使用 clouds.yaml
mkdir -p ~/.config/openstack
cat > ~/.config/openstack/clouds.yaml << EOF
clouds:
  nexus:
    auth:
      auth_url: "http://${PROXY_IP}/v3"
      project_name: "admin"
      username: "admin"
      password: "password"
      user_domain_name: "Default"
      project_domain_name: "Default"
    region_name: "RegionOne"
    interface: "public"
EOF

export OS_CLOUD=nexus
openstack server list

# 方式2: 使用环境变量
export OS_AUTH_URL="http://${PROXY_IP}/v3"
export OS_PROJECT_NAME="admin"
export OS_USERNAME="admin"
export OS_PASSWORD="password"
export OS_USER_DOMAIN_NAME="Default"
export OS_PROJECT_DOMAIN_NAME="Default"

openstack endpoint list
```

### Python SDK 配置

```python
import openstack

# 使用代理连接
conn = openstack.connect(
    auth_url=f'http://{proxy_ip}/v3',
    project_name='admin',
    username='admin',
    password='password',
    user_domain_name='Default',
    project_domain_name='Default'
)

# 列出服务器
for server in conn.compute.servers():
    print(server.name)
```

### cURL 测试

```bash
# 获取 Token
TOKEN=$(curl -s -X POST http://${PROXY_IP}/v3/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "auth": {
      "identity": {
        "methods": ["password"],
        "password": {
          "user": {
            "name": "admin",
            "domain": {"name": "Default"},
            "password": "password"
          }
        }
      },
      "scope": {
        "project": {
          "name": "admin",
          "domain": {"name": "Default"}
        }
      }
    }
  }' | grep -i x-subject-token | awk '{print $2}' | tr -d '\r')

# 使用 Token 访问 API
curl -H "X-Auth-Token: $TOKEN" http://${PROXY_IP}/v3/projects
```

## 🔍 监控和诊断

### 健康检查

```bash
# Nginx 健康检查
curl http://${PROXY_IP}:8080/nginx-health

# DNS 健康检查
dig @${DNS_IP} +short test.openstack.svc.cluster.local

# 服务发现状态
kubectl get cronjob nexus-discovery -n openstack-proxy
kubectl get jobs -l app=nexus,component=discovery -n openstack-proxy
```

### 性能测试

```bash
# HTTP 性能测试
ab -n 1000 -c 10 -H "Host: keystone.openstack.svc.cluster.local" http://${PROXY_IP}/v3

# DNS 性能测试
for i in {1..100}; do
  time dig @${DNS_IP} +short keystone.openstack.svc.cluster.local
done | grep real
```

### 日志分析

```bash
# 查看最近的错误
kubectl logs deployment/nexus-proxy -n openstack-proxy | grep ERROR

# 查看服务发现历史
kubectl logs -l app=nexus,component=discovery -n openstack-proxy --tail=100

# 实时监控日志
kubectl logs -f deployment/nexus-proxy -n openstack-proxy
kubectl logs -f deployment/nexus-dns -n openstack-proxy
```

## 🐛 常见问题排查

### 1. 服务发现不工作

```bash
# 检查 CronJob
kubectl describe cronjob nexus-discovery -n openstack-proxy

# 手动运行服务发现
kubectl create job --from=cronjob/nexus-discovery test-discovery -n openstack-proxy
kubectl logs job/test-discovery -n openstack-proxy

# 检查权限
kubectl auth can-i list services --as=system:serviceaccount:openstack-proxy:nexus-discovery -n openstack
```

### 2. DNS 解析失败

```bash
# 进入 DNS Pod 调试
kubectl exec -it deployment/nexus-dns -n openstack-proxy -- /bin/bash

# 在 Pod 内测试
cat /etc/dnsmasq.conf
dnsmasq --test
nslookup keystone.openstack localhost

# 检查配置文件
kubectl exec deployment/nexus-dns -n openstack-proxy -- cat /etc/dnsmasq.d/openstack.conf
```

### 3. 代理返回 503

```bash
# 检查后端服务
kubectl get svc -n openstack

# 检查代理配置
kubectl exec deployment/nexus-proxy -n openstack-proxy -- cat /etc/nginx/conf.d/default.conf

# 测试后端连接
kubectl exec deployment/nexus-proxy -n openstack-proxy -- curl -I keystone.openstack.svc.cluster.local
```

### 4. PVC 挂载问题

```bash
# 检查 PVC 状态
kubectl get pvc -n openstack-proxy
kubectl describe pvc nexus-shared-config -n openstack-proxy

# 检查存储类
kubectl get storageclass
kubectl describe storageclass <your-storage-class>

# 验证挂载
kubectl exec deployment/nexus-proxy -n openstack-proxy -- df -h /shared/config
```

## 🔄 升级策略

### 滚动升级

```bash
# 更新镜像版本
helm upgrade nexus . \
  --set images.tags.proxy=nginx:1.28-alpine \
  --set images.tags.dns=quay.io/openstack.kolla/dnsmasq:2025.1-ubuntu-noble \
  --reuse-values \
  -n openstack-proxy

# 监控升级过程
kubectl rollout status deployment/nexus-proxy -n openstack-proxy
kubectl rollout status deployment/nexus-dns -n openstack-proxy
```

### 配置热更新

```bash
# 更新配置后触发服务发现
kubectl create job --from=cronjob/nexus-discovery force-update -n openstack-proxy

# 监控配置更新
kubectl logs job/force-update -n openstack-proxy -f
```

## 🎯 最佳实践

### 生产环境建议

1. **高可用部署**
    - Proxy 至少 3 副本
    - DNS 至少 2 副本
    - 使用反亲和性规则分散到不同节点

2. **存储选择**
    - 使用支持 ReadWriteMany 的分布式存储
    - 定期备份配置 PVC

3. **监控告警**
    - 监控服务可用性
    - 设置日志聚合
    - 配置性能指标采集

4. **安全加固**
    - 启用 SSL/TLS
    - 配置网络策略
    - 定期更新镜像

### 性能优化

```yaml
# performance-values.yaml
proxy:
  worker_processes: auto
  worker_connections: 4096
  proxy_cache:
    enabled: true
    path: "/var/cache/nginx"
    max_size: "1g"
  proxy_timeouts:
    connect: 300s
    send: 300s
    read: 300s

dns:
  cache_size: 10000
  neg_ttl: 300
```

### 调试技巧

1. **启用详细日志**
   ```bash
   helm upgrade nexus . --set dns.log_queries=true --reuse-values -n openstack-proxy
   ```

2. **使用调试容器**
   ```bash
   kubectl run debug --image=nicolaka/netshoot --rm -it -n openstack-proxy -- /bin/bash
   ```

3. **配置验证**
   ```bash
   # 验证 Nginx 配置
   kubectl exec deployment/nexus-proxy -n openstack-proxy -- nginx -t
   
   # 验证 DNSMasq 配置
   kubectl exec deployment/nexus-dns -n openstack-proxy -- dnsmasq --test
   ```

## 📚 参考链接

- [Kubernetes 文档](https://kubernetes.io/docs/)
- [Helm 文档](https://helm.sh/docs/)
- [OpenStack API 参考](https://docs.openstack.org/api-ref/)
- [Nginx 配置指南](http://nginx.org/en/docs/)
- [DNSMasq 文档](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)