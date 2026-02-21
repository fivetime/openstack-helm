# 待解决问题记录

## Issue #1：deployment-worker 的管理网络访问方式未确定

### 问题描述

`deployment-worker.yaml` 目前的启动脚本 `_octavia-worker.sh.tpl` 里包含：

```bash
dhclient -v o-w0 -cf /tmp/dhclient.conf
```

但 `deployment-worker.yaml` 没有 `get-port` 和 `nic-init` 这两个 initContainer，`o-w0` 接口根本不会被创建，**Worker 启动时会直接报错失败**。

### 背景分析

上游 DaemonSet 方案的网络初始化流程：

1. `octavia-worker-get-port`（initContainer）→ 从 Neutron 获取该节点的端口信息（MAC、PORT_ID），写入 `/tmp/pod-shared/`
2. `octavia-worker-nic-init`（initContainer）→ 在 OVS 上创建 `o-w0` 接口并绑定 MAC
3. Worker 启动脚本 → `dhclient` 给 `o-w0` 获取 IP，启动 octavia-worker

Worker 使用 `amphora_haproxy_rest_driver`，需要通过 TLS REST API 直接访问 Amphora 管理网络 IP，必须能路由到管理网段。上游通过 `o-w0` OVS 接口实现，并配合 `hostNetwork: true` 使用宿主机网络栈。

### 为什么不能简单照搬 DaemonSet 的方案

`o-w0` 是**节点级资源**，不适合 Pod 级管理：

- DaemonSet：每节点固定一个 Pod，`o-w0` 与节点绑定，Pod 重启不换节点，`--may-exist` 保证幂等
- Deployment：Pod 可能被调度到任意节点，**Pod 销毁后旧节点的 `o-w0` 不会自动清理**，残留在 OVS 里
- 多副本时同一节点可能有多个 Pod 争用同一个 `o-w0` 接口
- 节点重复调度时端口状态可能异常

### 待确认事项

- [ ] network-node 宿主机上是否已有到 Amphora 管理网段的静态路由（不依赖 `o-w0`）？
- [ ] 是否可以去掉 `hostNetwork: true`，改用 CNI 网络访问管理网段？
- [ ] 如果去掉 `o-w0` 方案，Worker 能否正常连接 Amphora REST API？

### 解决方向

**方向一（推荐）：** 去掉 `dhclient` 和 `o-w0` 依赖，依赖宿主机已有路由访问管理网段。

需要：
1. 新建 `_octavia-deployment-worker.sh.tpl`，去掉 dhclient 相关内容
2. 在 `configmap-bin.yaml` 里注册新脚本
3. `deployment-worker.yaml` 挂载改为新脚本
4. 确认宿主机有路由能访问 Amphora 管理网段

**方向二：** 保留 `get-port` + `nic-init`，但增加 Pod 终止时的清理 hook（`preStop`），在 Pod 销毁时主动删除 `o-w0` 接口，解决残留问题。

需要：
1. 在 `deployment-worker.yaml` 加入两个 initContainer（同 daemonset）
2. 加入 `pod-shared` 和 `run` volume
3. 编写清理脚本，在 `preStop` 里执行 `ovs-vsctl del-port br-int o-w0`
4. 评估多副本时的端口冲突问题（同一节点多个副本不可行）

### 影响文件

- `octavia/templates/deployment-worker.yaml`
- `octavia/templates/bin/_octavia-worker.sh.tpl`
- `octavia/templates/configmap-bin.yaml`（如采用方向一）
