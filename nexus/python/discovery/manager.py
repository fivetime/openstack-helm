#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
配置管理模块
处理配置文件的保存、应用和状态管理
"""

import os
import json
import logging
from datetime import datetime
from typing import List, Dict

logger = logging.getLogger(__name__)

class ConfigManager:
    """配置管理器"""

    def __init__(self, work_dir: str, config_dir: str):
        self.work_dir = work_dir
        self.config_dir = config_dir
        os.makedirs(work_dir, exist_ok=True)
        os.makedirs(config_dir, exist_ok=True)

    def save_configs(self, nginx_config: str, dns_config: str) -> None:
        """保存配置文件"""
        with open(f"{self.work_dir}/nginx-default.conf", 'w') as f:
            f.write(nginx_config)

        with open(f"{self.work_dir}/dnsmasq-openstack.conf", 'w') as f:
            f.write(dns_config)

    def apply_configs(self) -> Dict[str, bool]:
        """应用配置文件"""
        results = {'nginx': False, 'dns': False}

        # 应用 Nginx 配置
        if os.system(f'/tmp/config-manager.sh write "{self.work_dir}/nginx-default.conf" nginx default') == 0:
            logger.info("Nginx 配置已更新")
            results['nginx'] = True

        # 应用 DNS 配置
        if os.environ.get('DNS_ENABLED', 'true').lower() == 'true':
            if os.system(f'/tmp/config-manager.sh write "{self.work_dir}/dnsmasq-openstack.conf" dnsmasq openstack') == 0:
                logger.info("DNS 配置已更新")
                results['dns'] = True

        return results

    def save_summary(self, services: List[Dict], proxy_target: str, results: Dict[str, bool]) -> None:
        """保存摘要信息"""
        summary = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'proxy_target': proxy_target,
            'service_count': len(services),
            'services': [s['name'] for s in services],
            'updates': results
        }

        with open(f"{self.config_dir}/discovery-summary.json", 'w') as f:
            json.dump(summary, f, indent=2)