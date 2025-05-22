# Kuryr-libnetwork Helm Chart

这是一个用于在Kubernetes上部署Kuryr-libnetwork的Helm Chart，它提供了Docker容器与OpenStack Neutron网络的集成。

## 概述

Kuryr-libnetwork是OpenStack Kuryr项目的一部分，它为Docker提供了一个网络插件，使Docker容器能够直接使用OpenStack Neutron网络服务。

## 前置条件

### OpenStack服务
- **Keystone**: 身份认证服务
- **Neutron**: 网络服务
- **OVS**: Open vSwitch（在计算节点上）

### Kubernetes环境
- Kubernetes 1.19+
- Helm 3.0+
- 计算节点上运行Docker守护进程

### 节点要求
- Docker socket可访问 (`/var/run/docker.sock`)
- Open vSwitch已安装并运行
- 网络连接到OpenStack服务

## 安装步骤

### 1. 准备节点标签
为需要运行Kuryr-libnetwork的节点添加标签：

```bash
kubectl label nodes <compute-node-1> kuryr-libnetwork=enabled
kubectl label nodes <compute-node-2> kuryr-libnetwork=enabled
```

### 2. 配置值文件
创建 `values-override.yaml` 文件：

```yaml
endpoints:
  identity:
    auth:
      admin:
        password: "your-admin-password"
      kuryr:
        password: "your-kuryr-password"
    hosts:
      default: keystone
      internal: keystone-api
  network:
    hosts:
      default: neutron
      internal: neutron-server

conf:
  kuryr:
    DEFAULT:
      debug: false  # 生产环境建议设为false
    neutron:
      project_name: service
```

### 3. 部署Chart
```bash
helm upgrade --install horizon openstack-helm/kuryr-libnetwork \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c kuryr-libnetwork values-override ${FEATURES})
```

## 验证安装

### 1. 检查Pod状态
```bash
kubectl get pods -l application=kuryr -o wide
```

### 2. 检查日志
```bash
kubectl logs -l application=kuryr -c kuryr-libnetwork
```

### 3. 验证Docker插件
在计算节点上：
```bash
# 检查插件文件
ls -la /usr/lib/docker/plugins/kuryr/

# 测试Docker网络
docker network ls
docker network create --driver=kuryr test-network
```

## 配置说明

### 重要配置项

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `labels.kuryr.node_selector_key` | 节点选择器键 | `kuryr-libnetwork` |
| `labels.kuryr.node_selector_value` | 节点选择器值 | `enabled` |
| `network.kuryr.docker_socket_path` | Docker socket路径 | `/var/run/docker.sock` |
| `network.kuryr.plugins_dir` | Docker插件目录 | `/usr/lib/docker/plugins/kuryr` |

### 安全配置
- Pod以root用户运行（必需）
- 使用特权容器（privileged: true）
- 挂载主机网络和PID命名空间

## 故障排除

### 常见问题

1. **Pod无法启动**
    - 检查节点是否有正确的标签
    - 验证Docker socket是否可访问
    - 检查OpenStack服务连接

2. **Docker网络插件未注册**
    - 确认 `/usr/lib/docker/plugins/kuryr/kuryr.spec` 文件存在
    - 检查Kuryr API是否在端口23750上监听

3. **网络连接失败**
    - 验证Neutron服务可达性
    - 检查Keystone认证配置
    - 确认OVS服务运行正常

### 日志位置
- Pod日志: `kubectl logs <pod-name> -c kuryr-libnetwork`
- 主机日志: `/var/log/kolla/kuryr/`

## 升级

```bash
helm upgrade --install horizon openstack-helm/kuryr-libnetwork \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c kuryr-libnetwork values-override ${FEATURES})
```

## 卸载

```bash
helm uninstall kuryr-libnetwork --namespace openstack
```

**注意**: 卸载前请确保没有Docker容器使用Kuryr网络。

## 参考文档

- [Kuryr官方文档](https://docs.openstack.org/kuryr-libnetwork/latest/)
- [OpenStack-Helm项目](https://opendev.org/openstack/openstack-helm)
- [Docker网络插件开发](https://docs.docker.com/engine/extend/plugins_network/)