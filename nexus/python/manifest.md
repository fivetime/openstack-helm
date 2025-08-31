# Nexus 服务发现 Python 模块结构

## 目录结构
```
nexus/
└── python/
    ├── nexus_discovery/
    │   ├── __init__.py
    │   ├── discovery.py     # 服务发现逻辑
    │   ├── config.py        # 配置生成器
    │   └── manager.py       # 配置管理器
    ├── auth.py              # OpenStack 认证
    ├── main.py              # 主程序入口
    ├── utils.py             # 工具函数
    └── requirements.txt     # Python 依赖
```

## 模块职责

### 1. **auth.py** - 认证模块
- 加载 Keystone 认证信息
- 建立 OpenStack 连接
- 验证连接状态

### 2. **discovery.py** - 服务发现模块
- 获取 OpenStack 服务目录
- 提取服务端点信息
- 确定代理目标 IP

### 3. **config.py** - 配置生成模块
- Nginx 配置生成器
- DNSMasq 配置生成器
- 配置模板管理

### 4. **manager.py** - 配置管理模块
- 保存发现结果
- 应用配置更改
- 生成状态摘要

### 5. **utils.py** - 工具函数
- 日志配置
- IP 验证
- 文件操作助手

### 6. **main.py** - 主程序
- 命令行参数解析
- 编排整个流程
- 异常处理