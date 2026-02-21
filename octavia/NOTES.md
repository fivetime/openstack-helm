# Octavia Worker 部署说明

## 背景

官方 openstack-helm 的 Octavia Worker 采用的是 `DaemonSet` 方式部署（文件为 `daemonset-worker.yaml`）。本项目认为 `DaemonSet` 不适合 Octavia Worker 的实际职责，因此新增了 `deployment-worker.yaml`，改用 `Deployment` 方式部署，并关闭上游的 `daemonset-worker.yaml`。

## 为什么 Octavia Worker 更适合 Deployment

### Octavia Worker 的职责

Octavia Worker（Controller Worker）本质上是一个**消息队列消费者**，通过 Oslo Messaging 接收来自 Octavia API 的请求，然后调用 Nova/Neutron API 创建和管理 Amphora 虚拟机。它是**无状态**的，多个实例之间完全对等，任何一个 Worker 实例都可以处理任何请求。

### 使用 Deployment 的理由

**1. 与节点无强绑定关系**

Worker 的工作是调用 OpenStack API，不需要操作宿主机网络设备，也不需要在每个节点上都存在。它运行在哪个节点上对功能没有影响。

**2. 副本数可按负载灵活调整**

Worker 是纯粹的计算密集型服务，请求量大时可以增加副本数提升吞吐量，与节点数量无关。DaemonSet 的副本数由节点数决定，无法独立扩缩容。

**3. Deployment 的调度更灵活**

配合 `affinity` 反亲和性配置，Deployment 可以将多个 Worker 副本分散到不同节点，同时允许在同一节点运行多个副本以满足高并发需求。DaemonSet 强制每节点只有一个 Pod，反而限制了扩展能力。

**4. 上游改为 DaemonSet 的原因分析**

上游在改为 DaemonSet 的同时新增了 `octavia-worker-nic-init` initContainer，用于初始化宿主机网卡。这说明上游的 DaemonSet 方案是针对特定网络架构设计的（每个节点都需要初始化专用网络接口）。本项目采用不同的网络方案，不需要此类初始化，因此 Deployment 方式更为适合。

## 文件说明

| 文件 | 说明 |
|------|------|
| `octavia/templates/deployment-worker.yaml` | 本项目自定义的 Worker Deployment 模板 |
| `octavia/templates/daemonset-worker.yaml` | 保留上游原始文件，默认关闭 |

## values.yaml 配置

```yaml
manifests:
  daemonset_worker: false    # 关闭上游 DaemonSet 方案
  deployment_worker: true    # 启用本项目 Deployment 方案

pod:
  replicas:
    worker: 2                # 根据实际负载调整副本数

  # 可选：挂载额外配置到 /etc/octavia/octavia.conf.d/
  etcSources:
    octavia_worker: []
```

## 部署注意事项

**1. 副本数设置**

`pod.replicas.worker` 根据实际请求量设置，建议至少 2 个副本保证高可用。不需要与节点数保持一致。

**2. 节点选择**

通过 `labels.worker.node_selector_key/value` 控制 Worker 调度到指定节点，建议调度到控制节点（Controller Node）。

**3. hostNetwork**

Worker 使用 `hostNetwork: true`，需确保所在节点能访问 Octavia 管理网络（o-w0 接口及 DHCP 配置由启动脚本处理）。

**4. 与上游同步时的注意事项**

- 上游对 `daemonset-worker.yaml` 的任何改动不影响本项目
- 若上游对 Worker 有功能性改动（如新增配置项支持），需手动评估并同步到 `deployment-worker.yaml`
- `values.yaml` 合并时注意保留 `deployment_worker: true` 和 `daemonset_worker: false`
