#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""配置生成模块 - 生成 Nginx 和 DNSMasq 配置"""

import os
from datetime import datetime
from typing import List, Dict, Set

NGINX_TEMPLATE = '''# OpenStack Nginx 代理配置
# 生成时间: {timestamp}
# 代理目标: {proxy_target}

upstream openstack_backend {{
    server {proxy_target}:80;
}}

server {{
    listen 80 default_server;
    server_name {server_names};

    location /nginx-health {{
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }}

    location / {{
        proxy_pass http://openstack_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        proxy_connect_timeout {connect_timeout};
        proxy_send_timeout {send_timeout};
        proxy_read_timeout {read_timeout};
        client_max_body_size {max_body_size};
        
        proxy_buffering off;
        proxy_request_buffering off;
    }}
}}
'''

DNS_TEMPLATE = '''# OpenStack DNS 配置
# 生成时间: {timestamp}
# 代理目标: {proxy_target}

# 通配符解析
address=/.{namespace}.svc.cluster.local/{proxy_target}
address=/.{namespace}.svc/{proxy_target}
address=/.{namespace}/{proxy_target}

# 服务解析
{service_entries}
'''


class ConfigGenerator:
    """配置文件生成器"""

    def __init__(self):
        self.namespace = os.environ.get('OPENSTACK_NAMESPACE', 'openstack')

    def generate_nginx(self, services: List[Dict], proxy_target: str, domains: Set[str]) -> str:
        """生成 Nginx 配置"""
        # 过滤通配符域名
        specific_domains = [d for d in domains
                            if not any(d.endswith(s) for s in [
                f'.{self.namespace}',
                f'.{self.namespace}.svc',
                f'.{self.namespace}.svc.cluster.local'
            ])]

        # 生成 server_name 列表
        server_names = ' '.join(sorted(specific_domains)) if specific_domains else '_'

        return NGINX_TEMPLATE.format(
            timestamp=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            proxy_target=proxy_target,
            server_names=server_names,
            connect_timeout=os.environ.get('PROXY_CONNECT_TIMEOUT', '600s'),
            send_timeout=os.environ.get('PROXY_SEND_TIMEOUT', '600s'),
            read_timeout=os.environ.get('PROXY_READ_TIMEOUT', '600s'),
            max_body_size=os.environ.get('PROXY_CLIENT_MAX_BODY_SIZE', '0')
        )

    def generate_dns(self, services: List[Dict], proxy_target: str) -> str:
        """生成 DNSMasq 配置"""
        entries = []

        # 获取所有唯一的主机名
        from .discovery import ServiceDiscovery
        discovery = ServiceDiscovery()
        hostnames = discovery.get_all_hostnames(services)

        # 为每个唯一主机名生成 DNS 记录
        for hostname in sorted(hostnames):
            entries.extend([
                f"address=/{hostname}/{proxy_target}",
                f"address=/{hostname}.{self.namespace}/{proxy_target}",
                f"address=/{hostname}.{self.namespace}.svc/{proxy_target}",
                f"address=/{hostname}.{self.namespace}.svc.cluster.local/{proxy_target}"
            ])

        return DNS_TEMPLATE.format(
            timestamp=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            proxy_target=proxy_target,
            namespace=self.namespace,
            service_entries='\n'.join(entries)
        )