#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
认证模块 - 处理 OpenStack 认证
"""

import os
import logging
from typing import Dict, List, Optional

import openstack

logger = logging.getLogger(__name__)

class OpenStackAuth:
    """OpenStack 认证管理器"""

    def __init__(self):
        self.conn = None
        self.catalog = []

    def connect(self) -> bool:
        """建立连接并获取服务目录"""
        try:
            # 加载认证配置
            auth_config = self._load_auth_config()
            logger.info("连接到 OpenStack...")

            # 建立连接
            self.conn = openstack.connect(**auth_config)
            self.conn.authorize()

            # 获取服务目录
            self.catalog = self._extract_catalog()
            logger.info(f"认证成功，获取到 {len(self.catalog)} 个服务")
            return True

        except Exception as e:
            logger.error(f"OpenStack 连接失败: {e}")
            return False

    def _load_auth_config(self) -> Dict[str, str]:
        """加载认证配置"""
        # 尝试从 Secret 文件读取
        config = {}
        secret_dir = "/tmp/keystone-secrets"

        mappings = {
            'OS_AUTH_URL': 'auth_url',
            'USERNAME': 'username',
            'PASSWORD': 'password',
            'PROJECT_NAME': 'project_name',
            'USER_DOMAIN_NAME': 'user_domain_name',
            'PROJECT_DOMAIN_NAME': 'project_domain_name',
            'REGION_NAME': 'region_name'
        }

        for key, param in mappings.items():
            # 优先从文件读取
            file_path = os.path.join(secret_dir, key)
            if os.path.exists(file_path):
                with open(file_path) as f:
                    config[param] = f.read().strip()
            else:
                # 从环境变量读取
                env_key = f"OS_{key}" if not key.startswith('OS_') else key
                config[param] = os.environ.get(env_key, '')

        # 设置默认值
        config.setdefault('interface', 'public')
        config.setdefault('identity_api_version', '3')
        config.setdefault('region_name', 'RegionOne')

        # 存储 auth_url 供后续使用
        self.auth_url = config.get('auth_url', '')

        return config

    def get_auth_ip(self) -> Optional[str]:
        """从认证 URL 中提取 IP"""
        try:
            if '://' in self.auth_url:
                host = self.auth_url.split('://')[1].split('/')[0].split(':')[0]
                parts = host.split('.')
                if len(parts) == 4 and all(0 <= int(p) <= 255 for p in parts):
                    return host
        except:
            pass
        return None

    def _extract_catalog(self) -> List[Dict]:
        """从认证响应提取服务目录"""
        try:
            auth = self.conn.session.auth
            access = auth.get_access(self.conn.session)

            # 尝试从 service_catalog 获取
            if hasattr(access, 'service_catalog'):
                return access.service_catalog.catalog

            # 从 token 数据获取
            if hasattr(access, '_data'):
                token_data = access._data
                if isinstance(token_data, dict):
                    return token_data.get('token', {}).get('catalog', [])

        except Exception as e:
            logger.error(f"提取服务目录失败: {e}")

        return []

    def close(self):
        """关闭连接"""
        if self.conn:
            self.conn.close()