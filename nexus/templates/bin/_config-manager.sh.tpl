#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
配置管理器 - 负责原子性配置更新和重载信号
*/}}

set -eo pipefail

SHARED_CONFIG_DIR="/shared/config"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CONFIG-MGR: $*"
}

error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# 原子性写入配置文件
atomic_write() {
    local source_file="$1"
    local service_type="$2"  # nginx 或 dnsmasq
    local config_name="$3"   # 配置文件名

    local target_dir="${SHARED_CONFIG_DIR}/${service_type}"
    local target_file="${target_dir}/${config_name}.conf"
    local temp_file="${target_file}.tmp"

    if [ ! -f "${source_file}" ]; then
        error_exit "Source file not found: ${source_file}"
    fi

    # 创建目标目录
    mkdir -p "${target_dir}"

    # 验证配置文件语法
    case "${service_type}" in
        "nginx")
            # 创建临时nginx配置进行测试
            local test_dir="/tmp/nginx-test-$$"
            mkdir -p "${test_dir}/conf.d"
            cp "${source_file}" "${test_dir}/conf.d/test.conf"

            # 创建基础nginx.conf用于测试
            cat > "${test_dir}/nginx.conf" << EOF
events { worker_connections 1024; }
http { include ${test_dir}/conf.d/*.conf; }
EOF

            if ! nginx -t -c "${test_dir}/nginx.conf" >/dev/null 2>&1; then
                rm -rf "${test_dir}"
                error_exit "Nginx configuration syntax check failed"
            fi
            rm -rf "${test_dir}"
            ;;
        "dnsmasq")
            if ! dnsmasq --test --conf-file="${source_file}" >/dev/null 2>&1; then
                error_exit "DNSMasq configuration syntax check failed"
            fi
            ;;
    esac

    # 原子性写入
    cp "${source_file}" "${temp_file}"

    # 检查是否有变化
    if [ -f "${target_file}" ] && cmp -s "${temp_file}" "${target_file}"; then
        rm -f "${temp_file}"
        log "No changes detected for ${service_type}/${config_name}"
        return 1  # 无变化
    fi

    mv "${temp_file}" "${target_file}"
    log "Configuration written: ${target_file}"

    # 发送重载信号
    touch "${SHARED_CONFIG_DIR}/reload_${service_type}"
    log "Reload signal sent for ${service_type}"

    return 0  # 有变化
}

# 读取配置文件
read_config() {
    local service_type="$1"
    local config_name="$2"
    local output_file="$3"

    local source_file="${SHARED_CONFIG_DIR}/${service_type}/${config_name}.conf"

    if [ ! -f "${source_file}" ]; then
        error_exit "Configuration file not found: ${source_file}"
    fi

    cp "${source_file}" "${output_file}"
    log "Configuration read: ${source_file} -> ${output_file}"
}

# 列出配置文件
list_configs() {
    local service_type="$1"
    local config_dir="${SHARED_CONFIG_DIR}/${service_type}"

    if [ -d "${config_dir}" ]; then
        find "${config_dir}" -name "*.conf" -type f | sort
    fi
}

# 备份配置
backup_config() {
    local service_type="$1"
    local backup_name="${2:-$(date +%Y%m%d_%H%M%S)}"

    local source_dir="${SHARED_CONFIG_DIR}/${service_type}"
    local backup_dir="${SHARED_CONFIG_DIR}/backups/${service_type}/${backup_name}"

    if [ -d "${source_dir}" ]; then
        mkdir -p "${backup_dir}"
        cp -r "${source_dir}"/* "${backup_dir}/" 2>/dev/null || true
        log "Configuration backed up: ${backup_dir}"
    fi
}

# 恢复配置
restore_config() {
    local service_type="$1"
    local backup_name="$2"

    local backup_dir="${SHARED_CONFIG_DIR}/backups/${service_type}/${backup_name}"
    local target_dir="${SHARED_CONFIG_DIR}/${service_type}"

    if [ ! -d "${backup_dir}" ]; then
        error_exit "Backup not found: ${backup_dir}"
    fi

    mkdir -p "${target_dir}"
    cp -r "${backup_dir}"/* "${target_dir}/"
    touch "${SHARED_CONFIG_DIR}/reload_${service_type}"
    log "Configuration restored from: ${backup_dir}"
}

# 显示帮助
show_help() {
    cat << EOF
Usage: $0 <command> [arguments...]

Commands:
  write <source_file> <service_type> <config_name>
    - Atomically write configuration file with syntax validation
    - service_type: nginx|dnsmasq
    - Returns 0 if changes applied, 1 if no changes

  read <service_type> <config_name> <output_file>
    - Read configuration file to output

  list <service_type>
    - List all configuration files for service type

  backup <service_type> [backup_name]
    - Backup current configuration (default: timestamp)

  restore <service_type> <backup_name>
    - Restore configuration from backup

Examples:
  $0 write /tmp/nginx.conf nginx default
  $0 read nginx default /tmp/current.conf
  $0 list nginx
  $0 backup nginx before_update
  $0 restore nginx before_update
EOF
}

# 主函数
main() {
    local command="${1:-help}"

    case "${command}" in
        "write")
            if [ $# -ne 4 ]; then
                echo "Usage: $0 write <source_file> <service_type> <config_name>" >&2
                exit 1
            fi
            atomic_write "$2" "$3" "$4"
            ;;
        "read")
            if [ $# -ne 4 ]; then
                echo "Usage: $0 read <service_type> <config_name> <output_file>" >&2
                exit 1
            fi
            read_config "$2" "$3" "$4"
            ;;
        "list")
            if [ $# -ne 2 ]; then
                echo "Usage: $0 list <service_type>" >&2
                exit 1
            fi
            list_configs "$2"
            ;;
        "backup")
            if [ $# -lt 2 ]; then
                echo "Usage: $0 backup <service_type> [backup_name]" >&2
                exit 1
            fi
            backup_config "$2" "$3"
            ;;
        "restore")
            if [ $# -ne 3 ]; then
                echo "Usage: $0 restore <service_type> <backup_name>" >&2
                exit 1
            fi
            restore_config "$2" "$3"
            ;;
        "help"|*)
            show_help
            ;;
    esac
}

main "$@"