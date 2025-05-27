#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
*/}}

set -eo pipefail

# 配置变量
SHARED_CONFIG_DIR="/shared/config"
DNSMASQ_CONFIG_DIR="${SHARED_CONFIG_DIR}/dnsmasq"
DNSMASQ_CONF_FILE="/etc/dnsmasq.d/openstack.conf"
RELOAD_CHECK_INTERVAL=10

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS: $*"
}

# 生成基础DNSMasq配置
generate_base_dnsmasq_config() {
    log "Generating base DNSMasq configuration..."

    cat > /etc/dnsmasq.conf << EOF
# 基础配置
port=53
domain-needed
bogus-priv
no-resolv
no-poll
bind-interfaces

# 上游DNS服务器
{{- range .Values.dns.upstream_dns }}
server={{ . }}
{{- end }}

# 缓存配置
cache-size={{ .Values.dns.cache_size }}
neg-ttl={{ .Values.dns.neg_ttl }}

{{- if .Values.dns.log_queries }}
# 日志配置
log-queries
log-facility={{ .Values.dns.log_file }}
{{- end }}

# 监听所有接口
interface=*

# 包含动态配置
conf-dir=/etc/dnsmasq.d/,*.conf
EOF
}

# 加载初始配置
load_initial_config() {
    log "Loading initial DNS configuration..."

    # 创建配置目录
    mkdir -p /etc/dnsmasq.d

    # 如果共享配置目录中有配置文件，使用它
    if [ -f "${DNSMASQ_CONFIG_DIR}/openstack.conf" ]; then
        log "Using existing configuration from shared storage"
        cp "${DNSMASQ_CONFIG_DIR}/openstack.conf" "${DNSMASQ_CONF_FILE}"
    else
        log "No existing configuration found, service discovery will provide one"
        # 创建一个最小的默认配置
        cat > "${DNSMASQ_CONF_FILE}" << EOF
# 默认DNS配置 - 等待服务发现
# 生成于 $(date)

# 临时配置，等待服务发现更新
EOF
    fi
}

# 设置日志
setup_logging() {
{{- if .Values.dns.log_queries }}
    log "Setting up logging..."

    # 创建日志目录
    mkdir -p "$(dirname {{ .Values.dns.log_file }})"

    # 确保日志文件存在且权限正确
    touch "{{ .Values.dns.log_file }}"
    chmod 644 "{{ .Values.dns.log_file }}"
{{- end }}
}

# 监控配置更新
monitor_config_updates() {
    log "Starting DNS configuration monitor..."

    while true; do
        # 检查是否有新的配置文件
        if [ -f "${DNSMASQ_CONFIG_DIR}/openstack.conf" ]; then
            # 检查配置是否发生变化
            if ! cmp -s "${DNSMASQ_CONFIG_DIR}/openstack.conf" "${DNSMASQ_CONF_FILE}" 2>/dev/null; then
                log "Detected DNS configuration change, updating..."

                # 复制新配置
                cp "${DNSMASQ_CONFIG_DIR}/openstack.conf" "${DNSMASQ_CONF_FILE}"

                # 测试配置
                if dnsmasq --test --conf-file=/etc/dnsmasq.conf >/dev/null 2>&1; then
                    log "Configuration test passed, reloading DNSMasq..."
                    # 发送HUP信号重载配置
                    if kill -HUP $(pgrep dnsmasq) 2>/dev/null; then
                        log "DNSMasq configuration reloaded successfully"
                    else
                        log "Failed to reload DNSMasq configuration"
                    fi
                else
                    log "DNSMasq configuration test failed, keeping old configuration"
                fi
            fi
        fi

        # 检查重载信号
        if [ -f "${SHARED_CONFIG_DIR}/reload_dnsmasq" ]; then
            log "Received DNS reload signal"
            rm -f "${SHARED_CONFIG_DIR}/reload_dnsmasq"

            if dnsmasq --test --conf-file=/etc/dnsmasq.conf >/dev/null 2>&1; then
                if kill -HUP $(pgrep dnsmasq) 2>/dev/null; then
                    log "DNSMasq reloaded via signal"
                else
                    log "Failed to reload DNSMasq via signal"
                fi
            else
                log "Configuration test failed, skipping reload"
            fi
        fi

        sleep "${RELOAD_CHECK_INTERVAL}"
    done
}

# 健康检查函数
health_check() {
    # 检查DNSMasq进程
    if ! pgrep dnsmasq >/dev/null; then
        log "DNSMasq process not found"
        return 1
    fi

    # 检查监听端口
    if ! ss -ulnp | grep -q ":{{ .Values.dns.port }} "; then
        log "DNSMasq not listening on UDP port"
        return 1
    fi

    if ! ss -tlnp | grep -q ":{{ .Values.dns.port }} "; then
        log "DNSMasq not listening on TCP port"
        return 1
    fi

    # 测试DNS解析
    if ! nslookup kubernetes.default.svc.cluster.local localhost >/dev/null 2>&1; then
        log "DNS resolution test failed"
        return 1
    fi

    return 0
}

# 主函数
main() {
    log "Starting DNSMasq DNS proxy server..."

    # 创建必要的目录
    mkdir -p "${SHARED_CONFIG_DIR}" "${DNSMASQ_CONFIG_DIR}" "/etc/dnsmasq.d"

    # 设置日志
    setup_logging

    # 生成基础配置
    generate_base_dnsmasq_config
    load_initial_config

    # 测试配置
    if ! dnsmasq --test --conf-file=/etc/dnsmasq.conf; then
        log "Initial configuration test failed"
        exit 1
    fi

    # 启动配置监控(后台)
    monitor_config_updates &
    MONITOR_PID=$!

    # 启动DNSMasq
    log "Starting DNSMasq..."
    dnsmasq --no-daemon --log-facility=- &
    DNSMASQ_PID=$!

    # 等待和健康检查循环
    wait_for_signal() {
        while true; do
            sleep 30

            # 健康检查
            if ! health_check; then
                log "Health check failed, restarting DNSMasq..."
                kill $DNSMASQ_PID 2>/dev/null || true
                sleep 5
                dnsmasq --no-daemon --log-facility=- &
                DNSMASQ_PID=$!
            fi

            # 检查DNSMasq进程是否还在运行
            if ! kill -0 $DNSMASQ_PID 2>/dev/null; then
                log "DNSMasq process died, restarting..."
                dnsmasq --no-daemon --log-facility=- &
                DNSMASQ_PID=$!
            fi
        done
    }

    # 信号处理
    cleanup() {
        log "Received termination signal, shutting down..."
        kill $DNSMASQ_PID $MONITOR_PID 2>/dev/null || true
        exit 0
    }

    trap cleanup TERM INT

    # 等待信号或进程结束
    wait_for_signal
}

# 运行主函数
main "$@"