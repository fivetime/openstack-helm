# Nexus 部署示例和最佳实践

## 🚀 快速部署示例

### 1. 最小化部署（开发环境）

```bash
# 创建开发环境配置
cat > dev-values.yaml << 'EOF'
# 开发环境 - 最小化配置
proxy:
  service_type: NodePort
  ssl:
    enabled: false

dns:
  enabled: false  # 开发环境可关闭DNS

discovery:
  interval: 2  # 更频繁的发现间隔
  openstack_namespace: "openstack"
  fallback_target: "10.0.30.110"

# 单副本部署
pod:
  replicas:
    proxy: 1
    dns: 1

# 使用本地存储
storage:
  shared_config:
    class: "hostpath"
    size: "500Mi"

# 关闭不需要的功能
manifests:
  certificates: false
  network_policy: false
EOF

# 部署
helm install nexus ./nexus -f dev-values.yaml -n openstack-dev --create-namespace
```

### 2. 生产环境部署

```bash
# 创建生产环境配置
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
  proxy_cache:
    enabled: true

dns:
  enabled: true
  service_type: LoadBalancer
  loadbalancer_ip: "192.168.1.101"
  upstream_dns:
    - "8.8.8.8"
    - "8.8.4.4"
    - "1.1.1.1"

# 服务发现配置
discovery:
  enabled: true
  interval: 5
  openstack_namespace: "openstack"
  public_service_name: "public-openstack"
  fallback_target: "10.0.30.110"
  use_openstack_cli: false

# 高可用配置
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
    dns:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "1000m"

# 生产级存储
storage:
  shared_config:
    enabled: true
    size: "2Gi"
    class: "nfs-client"  # 或其他支持ReadWriteMany的存储类
    access_mode: "ReadWriteMany"

# 启用网络策略
network_policy:
  nexus:
    ingress:
      - {}
    egress:
      - to:
          - namespaceSelector:
              matchLabels:
                name: openstack
        ports:
          - protocol: TCP
            port: 80
          - protocol: TCP
            port: 443

manifests:
  network_policy: true
  certificates: true
EOF

# 部署
helm install nexus ./nexus -f prod-values.yaml -n openstack-proxy --create-namespace
```

### 3. 带OpenStack CLI认证的部署

```bash
cat > auth-values.yaml << 'EOF'
# 启用OpenStack CLI认证
discovery:
  enabled: true
  use_openstack_cli: true
  hybrid_discovery: true

# 配置OpenStack认证
endpoints:
  identity:
    auth:
      admin:
        region_name: RegionOne
        username: admin
        password: "your-admin-password"
        project_name: admin
        user_domain_name: default
        project_domain_name: default

manifests:
  secret_keystone: true
EOF

helm install nexus ./nexus -f auth-values.yaml -n openstack-proxy --create-namespace
```

## 🔧 部署后配置

### 获取服务地址

```bash
# 获取代理服务地址
PROXY_IP=$(kubectl get svc nexus-proxy -n openstack-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
PROXY_PORT=$(kubectl get svc nexus-proxy -n openstack-proxy -o jsonpath='{.spec.ports[0].port}')
echo "代理服务地址: http://${PROXY_IP}:${PROXY_PORT}"

# 获取DNS服务地址
DNS_IP=$(kubectl get svc nexus-dns -n openstack-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "DNS服务地址: ${DNS_IP}:53"
```

### 配置OpenStack客户端

#### 1. 使用HTTP代理

```bash
# 创建OpenStack配置
mkdir -p ~/.config/openstack
cat > ~/.config/openstack/clouds.yaml << EOF
clouds:
  nexus-proxy:
    region_name: RegionOne
    identity_api_version: 3
    auth:
      username: 'admin'
      password: 'your-password'
      project_name: 'admin'
      project_domain_name: 'default'
      user_domain_name: 'default'
      auth_url: 'http://${PROXY_IP}/v3'
    interface: public
    verify: false  # 如果使用自签名证书
EOF

# 使用配置
export OS_CLOUD=nexus-proxy
openstack endpoint list
openstack server list
```

#### 2. 配置DNS客户端

```bash
# 在客户端机器上配置DNS
echo "nameserver ${DNS_IP}" | sudo tee /etc/resolv.conf

# 或者配置dnsmasq转发
echo "server=/openstack.svc.cluster.local/${DNS_IP}" | sudo tee -a /etc/dnsmasq.conf
sudo systemctl restart dnsmasq

# 测试DNS解析
nslookup keystone.openstack.svc.cluster.local ${DNS_IP}
```

## 🧪 测试和验证

### 基础连通性测试

```bash
# 1. 测试HTTP代理
curl -H "Host: keystone.openstack.svc.cluster.local" http://${PROXY_IP}/v3

# 2. 测试HTTPS代理（如果启用）
curl -k -H "Host: keystone.openstack.svc.cluster.local" https://${PROXY_IP}/v3

# 3. 测试DNS解析
nslookup keystone.openstack.svc.cluster.local ${DNS_IP}
nslookup nova-api.openstack.svc.cluster.local ${DNS_IP}

# 4. 测试健康检查端点
curl http://${PROXY_IP}:8080/nginx-health
```

### OpenStack API测试

```bash
# 获取认证token
TOKEN=$(curl -i -X POST http://${PROXY_IP}/v3/auth/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "auth": {
      "identity": {
        "methods": ["password"],
        "password": {
          "user": {
            "name": "admin",
            "domain": {"name": "Default"},
            "password": "your-password"
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
  }' 2>/dev/null | grep -i "X-Subject-Token" | cut -d' ' -f2 | tr -d '\r')

# 测试各个服务
curl -H "X-Auth-Token: $TOKEN" http://${PROXY_IP}/v3/projects
curl -H "X-Auth-Token: $TOKEN" http://${PROXY_IP}:8774/v2.1/servers
curl -H "X-Auth-Token: $TOKEN" http://${PROXY_IP}:9696/v2.0/networks
```

### 性能测试

```bash
# DNS响应时间测试
for i in {1..10}; do
  time nslookup keystone.openstack.svc.cluster.local ${DNS_IP} >/dev/null
done

# HTTP响应时间测试
for service in keystone nova-api neutron-server glance-api; do
  echo "测试 $service:"
  curl -o /dev/null -s -w "Time: %{time_total}s, Status: %{http_code}\n" \
    -H "Host: $service.openstack.svc.cluster.local" \
    http://${PROXY_IP}/
done

# 并发测试
ab -n 100 -c 10 -H "Host: keystone.openstack.svc.cluster.local" http://${PROXY_IP}/v3/
```

## 🔄 运维操作指南

### 配置更新

```bash
# 更新配置
helm upgrade nexus ./nexus -f prod-values.yaml -n openstack-proxy

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
helm upgrade nexus ./nexus \
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

## 🐛 故障排除实例

### 问题1: LoadBalancer IP一直Pending

```bash
# 检查LoadBalancer控制器
kubectl get pods -n metallb-system
kubectl logs -f deployment/controller -n metallb-system

# 检查IP池配置
kubectl get ipaddresspool -n metallb-system
kubectl describe ipaddresspool -n metallb-system

# 临时使用NodePort
helm upgrade nexus ./nexus \
  --set proxy.service_type=NodePort \
  --set dns.service_type=NodePort \
  --reuse-values \
  -n openstack-proxy
```

### 问题2: 服务发现失败

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

### 问题3: 配置更新不生效

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

### 问题4: SSL证书问题

```bash
# 检查证书
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- ls -la /etc/nginx/ssl/
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- openssl x509 -in /etc/nginx/ssl/tls.crt -text -noout

# 重新生成证书
kubectl exec -it deployment/nexus-proxy -n openstack-proxy -- rm -f /etc/nginx/ssl/*
kubectl rollout restart deployment/nexus-proxy -n openstack-proxy
```

## 📊 监控和告警

### Prometheus监控配置

```yaml
# prometheus-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nexus-monitoring
  namespace: openstack-proxy
spec:
  selector:
    matchLabels:
      app: nexus
  endpoints:
    - port: metrics
      path: /nginx_status
      interval: 30s
```

### Grafana仪表板指标

- Nginx连接数和请求数
- DNS查询数量和响应时间
- 服务发现成功/失败次数
- Pod资源使用情况
- LoadBalancer流量统计

### 日志聚合

```bash
# 使用Fluentd收集日志
kubectl logs -f -l app=nexus --tail=100 -n openstack-proxy | grep ERROR
kubectl logs -f -l app=nexus,component=discovery --tail=50 -n openstack-proxy
```

## 🔒 安全最佳实践

### 网络策略配置

```yaml
# 限制入站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nexus-ingress-policy
  namespace: openstack-proxy
spec:
  podSelector:
    matchLabels:
      app: nexus
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: openstack
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
```

### 访问控制

```bash
# 限制服务发现权限
kubectl create role nexus-limited --verb=get,list --resource=services,endpoints -n openstack
kubectl create rolebinding nexus-binding --role=nexus-limited --serviceaccount=openstack-proxy:nexus-discovery -n openstack
```

### 高级配置示例

#### 1. 多环境部署

```bash
# 预发布环境
cat > staging-values.yaml << 'EOF'
proxy:
  loadbalancer_ip: "192.168.1.200"
  ssl:
    enabled: true
    
discovery:
  openstack_namespace: "openstack-staging"
  fallback_target: "10.0.30.120"

pod:
  replicas:
    proxy: 2
    dns: 1
EOF

helm install nexus-staging ./nexus -f staging-values.yaml -n openstack-staging --create-namespace
```

#### 2. 多区域配置

```bash
# 区域A配置
cat > region-a-values.yaml << 'EOF'
proxy:
  loadbalancer_ip: "192.168.1.100"
  
discovery:
  openstack_namespace: "openstack-region-a"
  public_service_name: "public-openstack-region-a"
  
endpoints:
  identity:
    auth:
      admin:
        region_name: RegionA
EOF

# 区域B配置  
cat > region-b-values.yaml << 'EOF'
proxy:
  loadbalancer_ip: "192.168.1.110"
  
discovery:
  openstack_namespace: "openstack-region-b"
  public_service_name: "public-openstack-region-b"
  
endpoints:
  identity:
    auth:
      admin:
        region_name: RegionB
EOF
```

#### 3. 混合云配置

```bash
# 支持多个OpenStack集群
cat > hybrid-values.yaml << 'EOF'
discovery:
  enabled: true
  multiple_clusters:
    - name: "cluster-a"
      namespace: "openstack-a"
      priority: 1
    - name: "cluster-b"  
      namespace: "openstack-b"
      priority: 2
  
proxy:
    upstream_config:
      backup_clusters:
        - "cluster-b.example.com:443"
      health_check: true
EOF
```

## 🚀 高级功能

### 1. 自定义路由规则

```bash
# 基于路径的路由
cat > custom-routing-values.yaml << 'EOF'
proxy:
  custom_routes:
    - path: "/v3/auth"
      upstream: "keystone-auth.openstack.svc.cluster.local"
    - path: "/compute"
      upstream: "nova-api.openstack.svc.cluster.local"
    - path: "/network"
      upstream: "neutron-server.openstack.svc.cluster.local"
EOF
```

### 2. 缓存配置

```bash
# 启用智能缓存
cat > cache-values.yaml << 'EOF'
proxy:
  proxy_cache:
    enabled: true
    cache_zones:
      - name: "api_cache"
        size: "100m"
        inactive: "60m"
    cache_rules:
      - location: "/v3/auth/tokens"
        cache_time: "0"  # 不缓存认证token
      - location: "/v3/projects"
        cache_time: "5m"
      - location: "/v2.1/flavors"
        cache_time: "30m"
EOF
```

### 3. 限流配置

```bash
# API限流保护
cat > rate-limit-values.yaml << 'EOF'
proxy:
  rate_limiting:
    enabled: true
    zones:
      - name: "api_limit"
        key: "$binary_remote_addr"
        size: "10m"
        rate: "10r/s"
    rules:
      - location: "/v3/auth"
        zone: "api_limit"
        burst: 20
      - location: "/v2.1/"
        zone: "api_limit"  
        burst: 50
EOF
```

这套完整的配置和示例为您在各种环境下部署和使用Nexus提供了全面的指导。