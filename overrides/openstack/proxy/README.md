# OpenStack透明代理工具

## 用途与背景

这套工具专为解决以下场景而设计：在混合环境（Kubernetes + 裸机）中，裸机上的应用需要访问部署在Kubernetes中的OpenStack服务。

**主要使用场景**:
- 运行在裸机服务器上的OpenStack客户端工具（CLI、SDK）
- 裸机上的应用需要与K8s中的OpenStack API进行交互
- 无需修改裸机应用配置即可连接到OpenStack服务

**问题解决**:
此工具解决了裸机环境无法直接解析Kubernetes内服务域名的问题，避免了手动维护hosts文件的繁琐工作，并提供了透明的请求转发机制。

## 工具组件

此工具包由四个核心脚本组成，提供模块化和灵活的部署选项：

1. **common-module.sh** - 公共函数库
    - 为所有脚本提供共享配置和功能
    - 自动发现K8s中部署的所有OpenStack服务

2. **generate-dnsmasq.sh** - DNS解析服务
    - 生成dnsmasq配置，自动解析所有OpenStack服务域名
    - 支持IPv4和IPv6双栈解析
    - 可独立运行，适合只需要域名解析的场景

3. **generate-nginx.sh** - HTTP代理服务
    - 生成nginx配置，转发HTTP/HTTPS请求到OpenStack服务
    - 保留原始Host头和路径信息，实现透明代理
    - 为每个OpenStack服务端口提供IPv4/IPv6监听

4. **deploy-all.sh** - 一键部署脚本
    - 自动安装和配置所有必要组件
    - 启用IPv6支持并配置防火墙规则
    - 提供部署验证和客户端配置指南

## 技术特性

- **完整服务发现**: 自动发现K8s中的所有OpenStack服务组件
- **多域名格式支持**: 处理所有OpenStack域名格式（短名称、中间形式、完整域名）
- **IPv4/IPv6双栈**: 前端支持双栈连接，后端使用稳定的IPv4连接
- **零配置客户端**: 裸机客户端无需特殊配置即可使用OpenStack服务
- **自动更新能力**: 可配置为定期运行，自动发现新服务组件
- **模块化部署**: 可以根据需要选择部署DNS、HTTP代理或全部组件

## 快速开始

### 安装

1. 下载所有脚本到同一目录：
```bash
git clone https://your-repo/openstack-proxy.git
cd openstack-proxy
chmod +x *.sh
```

2. 修改配置（如需要）：
   编辑`common-module.sh`中的IP地址配置

### 部署

**选项1：一键部署全部组件**
```bash
sudo ./deploy-all.sh
```

**选项2：仅部署DNS服务**
```bash
./generate-dnsmasq.sh
# 按提示确认部署
```

**选项3：仅部署HTTP代理**
```bash
./generate-nginx.sh
# 按提示确认部署
```

### 客户端配置

部署完成后，客户端只需将DNS设置指向代理服务器：

```bash
# 修改/etc/resolv.conf
nameserver 10.0.16.10  # 使用代理服务器IPv4
nameserver fd00:1:1:0:10:0:16:10  # 使用代理服务器IPv6
```

然后就可以直接使用OpenStack服务，无需任何其他配置：
```bash
# 示例：使用OpenStack CLI
export OS_AUTH_URL="http://keystone/v3"
openstack token issue

# 或使用完整域名
export OS_AUTH_URL="http://keystone.openstack.svc.cluster.local/v3"
openstack token issue
```

## 维护与更新

当OpenStack服务更新或添加新组件时：
```bash
# 重新运行部署脚本即可自动发现新服务
sudo ./deploy-all.sh
```

## 问题排查

**DNS解析问题**：
```bash
# 验证DNS解析
dig @10.0.16.10 keystone.openstack.svc.cluster.local
# 或IPv6
dig @fd00:1:1:0:10:0:16:10 AAAA keystone.openstack.svc.cluster.local
```

**HTTP代理问题**：
```bash
# 验证HTTP连接
curl -v http://keystone/v3
# 验证HTTPS连接
curl -v -k https://keystone/v3
# 验证IPv6连接
curl -v -6 http://[fd00:1:1:0:10:0:16:10]/v3
```

## 高级配置

**定期自动更新**：
```bash
# 添加定时任务，每周日凌晨3点更新配置
echo "0 3 * * 0 /path/to/deploy-all.sh > /var/log/openstack-proxy-update.log 2>&1" | sudo crontab -
```

**自定义端口**：
要添加特定端口的监听，编辑`generate-nginx.sh`脚本中的端口列表。

## 许可证

本工具基于开源许可证提供。欢迎贡献和改进。