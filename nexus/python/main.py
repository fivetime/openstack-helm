#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nexus 服务发现主程序
编排整个服务发现和配置更新流程
"""

import argparse
import logging
import os
import sys

# 添加模块路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from discovery import (
    ServiceDiscovery,
    ConfigGenerator,
    ConfigManager
)
from auth import OpenStackAuth

# 设置日志
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(name)s - %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


def main():
    """主函数"""
    parser = argparse.ArgumentParser(description='Nexus OpenStack 服务发现')
    parser.add_argument('--work-dir', default='/tmp/discovery', help='工作目录')
    parser.add_argument('--config-dir', default='/shared/config', help='配置目录')
    parser.add_argument('--debug', action='store_true', help='调试模式')

    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    try:
        logger.info("启动 OpenStack 服务发现...")

        # 初始化组件
        auth = OpenStackAuth()
        discovery = ServiceDiscovery()
        generator = ConfigGenerator()
        manager = ConfigManager(args.work_dir, args.config_dir)

        # 1. 连接并获取服务目录
        if not auth.connect():
            logger.error("无法连接到 OpenStack")
            return 1

        # 2. 处理服务目录
        services, proxy_target = discovery.process_catalog(auth.catalog)

        # 如果没有从 catalog 获取到 IP，尝试从 auth URL 获取
        if not discovery._is_ip(proxy_target):
            auth_ip = auth.get_auth_ip()
            if auth_ip:
                proxy_target = auth_ip
                logger.info(f"使用认证 URL 中的 IP: {proxy_target}")
            else:
                # 如果都失败了，使用默认值
                proxy_target = discovery.fallback_ip
                logger.warning(f"无法获取有效 IP，使用默认值: {proxy_target}")

        # 3. 生成域名列表
        domains = discovery.generate_domains(services)

        # 4. 生成配置
        nginx_config = generator.generate_nginx(services, proxy_target, domains)
        dns_config = generator.generate_dns(services, proxy_target)

        # 5. 保存并应用配置
        manager.save_configs(nginx_config, dns_config)
        results = manager.apply_configs()

        # 6. 保存摘要
        manager.save_summary(services, proxy_target, results)

        # 清理
        auth.close()

        logger.info("服务发现完成")
        return 0

    except Exception as e:
        logger.error(f"服务发现失败: {e}", exc_info=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())