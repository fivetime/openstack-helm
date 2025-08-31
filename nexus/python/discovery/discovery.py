#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
服务发现 - 处理服务和端点信息
"""

import logging
import os
from typing import List, Dict, Tuple, Set
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

class ServiceDiscovery:
    """服务发现处理器"""

    def __init__(self):
        self.namespace = os.environ.get('OPENSTACK_NAMESPACE', 'openstack')
        self.public_service = os.environ.get('PUBLIC_SERVICE_NAME', 'public-openstack')
        self.fallback_ip = os.environ.get('FALLBACK_TARGET', '127.0.0.1')
        self.region = os.environ.get('OS_REGION_NAME', 'RegionOne')

    def process_catalog(self, catalog: List[Dict]) -> Tuple[List[Dict], str]:
        """处理服务目录，返回服务列表和代理目标"""
        services = []
        proxy_target = self.fallback_ip
        all_endpoints = []

        for item in catalog:
            service = {
                'name': item.get('name', ''),
                'type': item.get('type', ''),
                'endpoints': []
            }

            # 筛选当前区域的端点
            for ep in item.get('endpoints', []):
                if ep.get('region', ep.get('region_id')) == self.region:
                    parsed = urlparse(ep.get('url', ''))
                    endpoint_info = {
                        'interface': ep.get('interface', ''),
                        'url': ep.get('url', ''),
                        'hostname': parsed.hostname or '',
                        'port': parsed.port,
                        'scheme': parsed.scheme,
                        'path': parsed.path
                    }
                    service['endpoints'].append(endpoint_info)
                    all_endpoints.append(endpoint_info)

                    # 从任何 public 端点提取 IP
                    if ep.get('interface') == 'public' and self._is_ip(parsed.hostname):
                        proxy_target = parsed.hostname
                        logger.debug(f"从 {service['name']} 的 public 端点提取到 IP: {proxy_target}")

            if service['endpoints']:
                services.append(service)

        logger.info(f"处理完成: {len(services)} 个服务, {len(all_endpoints)} 个端点, 代理目标: {proxy_target}")
        return services, proxy_target

    def get_all_hostnames(self, services: List[Dict]) -> Set[str]:
        """获取所有唯一的主机名"""
        hostnames = set()

        for service in services:
            # 添加服务名
            hostnames.add(service['name'])

            # 添加端点主机名
            for endpoint in service['endpoints']:
                hostname = endpoint['hostname']
                if hostname and not self._is_ip(hostname):
                    # 如果是完整域名，只提取主机名部分
                    if '.openstack.svc.cluster.local' in hostname:
                        base_hostname = hostname.split('.')[0]
                        hostnames.add(base_hostname)
                    else:
                        hostnames.add(hostname)

        return hostnames

    def generate_domains(self, services: List[Dict]) -> Set[str]:
        """生成域名集合"""
        domains = set()

        # 获取所有主机名
        hostnames = self.get_all_hostnames(services)

        for hostname in hostnames:
            # 添加各种域名格式
            domains.update([
                hostname,
                f"{hostname}.{self.namespace}",
                f"{hostname}.{self.namespace}.svc",
                f"{hostname}.{self.namespace}.svc.cluster.local"
            ])

        return domains

    def _is_ip(self, text: str) -> bool:

        """检查是否为 IP 地址"""
        if not text:
            return False
        try:
            parts = text.split('.')
            return len(parts) == 4 and all(0 <= int(p) <= 255 for p in parts)
        except:
            return False