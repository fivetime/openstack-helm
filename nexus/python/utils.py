#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
工具函数模块
提供通用的辅助函数
"""

import logging
import sys
import ipaddress


def setup_logging(debug: bool = False) -> None:
    """配置日志系统"""
    level = logging.DEBUG if debug else logging.INFO

    # 配置根日志器
    logging.basicConfig(
        level=level,
        format='[%(asctime)s] %(name)s - %(levelname)s: %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S',
        stream=sys.stdout
    )

    # 调整第三方库日志级别
    if not debug:
        logging.getLogger('urllib3').setLevel(logging.WARNING)
        logging.getLogger('openstack').setLevel(logging.WARNING)
        logging.getLogger('keystoneauth').setLevel(logging.WARNING)


def is_valid_ip(ip: str) -> bool:
    """
    验证 IP 地址格式（支持 IPv4 和 IPv6）

    Args:
        ip: IP 地址字符串

    Returns:
        bool: 是否为有效的 IP 地址
    """
    try:
        ipaddress.ip_address(ip)
        return True
    except ValueError:
        return False


def is_valid_ipv4(ip: str) -> bool:
    """
    验证 IPv4 地址格式

    Args:
        ip: IP 地址字符串

    Returns:
        bool: 是否为有效的 IPv4 地址
    """
    try:
        ipaddress.IPv4Address(ip)
        return True
    except ValueError:
        return False


def is_valid_ipv6(ip: str) -> bool:
    """
    验证 IPv6 地址格式

    Args:
        ip: IP 地址字符串

    Returns:
        bool: 是否为有效的 IPv6 地址
    """
    try:
        ipaddress.IPv6Address(ip)
        return True
    except ValueError:
        return False


def ensure_dir(path: str) -> None:
    """确保目录存在"""
    import os
    os.makedirs(path, exist_ok=True)


def read_file_safe(filepath: str, default: str = "") -> str:
    """
    安全地读取文件内容

    Args:
        filepath: 文件路径
        default: 文件不存在时的默认值

    Returns:
        str: 文件内容或默认值
    """
    try:
        with open(filepath, 'r') as f:
            return f.read().strip()
    except (IOError, OSError):
        return default


def write_file_safe(filepath: str, content: str) -> bool:
    """
    安全地写入文件

    Args:
        filepath: 文件路径
        content: 要写入的内容

    Returns:
        bool: 是否成功写入
    """
    try:
        import os
        # 确保目录存在
        ensure_dir(os.path.dirname(filepath))

        # 原子写入
        temp_file = f"{filepath}.tmp"
        with open(temp_file, 'w') as f:
            f.write(content)

        os.replace(temp_file, filepath)
        return True

    except (IOError, OSError) as e:
        logging.error(f"写入文件失败 {filepath}: {e}")
        return False


def get_env_bool(key: str, default: bool = False) -> bool:
    """
    从环境变量获取布尔值

    Args:
        key: 环境变量名
        default: 默认值

    Returns:
        bool: 环境变量的布尔值
    """
    import os
    value = os.environ.get(key, '').lower()

    if not value:
        return default

    return value in ('true', '1', 'yes', 'on')