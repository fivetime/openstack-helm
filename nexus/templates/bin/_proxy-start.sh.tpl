#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
*/}}

set -eo pipefail

# 配置变量
SHARED_CONFIG_DIR="/shared/config"
NGINX_CONFIG_DIR="${SHARED_CONFIG_DIR}/nginx"
NGINX_CONF_FILE="/etc/nginx/conf.d/default.conf"
RELOAD_CHECK_INTERVAL=10

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROXY: $*"
}

# 初始化SSL证书
init_ssl_certificates() {
{{- if .Values.proxy.ssl.enabled }}
    log "Initializing SSL certificates..."

    mkdir -p /etc/nginx/ssl

{{- if .Values.proxy.ssl.auto_generate }}
    # 生成自签名证书
    if [ ! -f "/etc/nginx/ssl/tls.crt" ]; then
        log "Generating self-signed SSL certificate..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/tls.key \
            -out /etc/nginx/ssl/tls.crt \
            -subj "/CN=openstack-proxy/O=OpenStack/C=US"

        chmod 600 /etc/nginx/ssl/tls.key
        chmod 644 /etc/nginx/ssl/tls.crt
        log "SSL certificate generated"
    fi
{{- else }}
    # 使用提供的证书
    if [ -n "{{ .Values.proxy.ssl.cert }}" ] && [ -n "{{ .Values.proxy.ssl.key }}" ]; then
        echo "{{ .Values.proxy.ssl.cert }}" > /etc/nginx/ssl/tls.crt
        echo "{{ .Values.proxy.ssl.key }}" > /etc/nginx/ssl/tls.key
        chmod 600 /etc/nginx/ssl/tls.key
        chmod 644 /etc/nginx/ssl/tls.crt
        log "SSL certificate configured from values"
    fi
{{- end }}
{{- end }}
}

# 生成基础Nginx配置
generate_base_nginx_config() {
    log "Generating base Nginx configuration..."

    cat > /etc/nginx/nginx.conf << EOF
user nginx;
worker_processes {{ .Values.proxy.worker_processes }};
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections {{ .Values.proxy.worker_connections }};
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 日志格式
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    # 基础配置
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # 客户端配置
    client_max_body_size {{ .Values.proxy.client_max_body_size }};
    client_body_buffer_size 128k;
    client_header_buffer_size 32k;
    large_client_header_buffers 4 32k;

    # 代理缓冲配置
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_buffer_size 16k;
    proxy_buffers 16 16k;
    proxy_busy_buffers_size 32k;

{{- if .Values.proxy.proxy_cache.enabled }}
    # 代理缓存配置
    proxy_cache_path {{ .Values.proxy.proxy_cache.path }} 
                     levels={{ .Values.proxy.proxy_cache.levels }}
                     keys_zone={{ .Values.proxy.proxy_cache.keys_zone }}
                     max_size={{ .Values.proxy.proxy_cache.max_size }}
                     inactive={{ .Values.proxy.proxy_cache.inactive }};
{{- end }}

    # 包含动态配置
    include /etc/nginx/conf.d/*.conf;
}
EOF
}

# 加载初始配置
load_initial_config() {
    log "Loading initial configuration..."

    # 如果共享配置目录中有配置文件，使用它
    if [ -f "${NGINX_CONFIG_DIR}/default.conf" ]; then
        log "Using existing configuration from shared storage"
        cp "${NGINX_CONFIG_DIR}/default.conf" "${NGINX_CONF_FILE}"
    else
        log "No existing configuration found, service discovery will provide one"
        # 创建一个最小的默认配置
        cat > "${NGINX_CONF_FILE}" << EOF
# 默认配置 - 等待服务发现
server {
    listen {{ .Values.proxy.ports.http }} default_server;
    server_name _;

    location /nginx-health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }

    location / {
        return 503 "Service discovery in progress";
        add_header Content-Type text/plain;
    }
}

{{- if .Values.proxy.ssl.enabled }}
server {
    listen {{ .Values.proxy.ports.https }} ssl default_server;
    server_name _;

    ssl_certificate /etc/nginx/ssl/tls.crt;
    ssl_certificate_key /etc/nginx/ssl/tls.key;

    location /nginx-health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }

    location / {
        return 503 "Service discovery in progress";
        add_header Content-Type text/plain;
    }
}
{{- end }}
EOF
    fi
}

# 监控配置更新
monitor_config_updates() {
    log "Starting configuration monitor..."

    while true; do
        # 检查是否有新的配置文件
        if [ -f "${NGINX_CONFIG_DIR}/default.conf" ]; then
            # 检查配置是否发生变化
            if ! cmp -s "${NGINX_CONFIG_DIR}/default.conf" "${NGINX_CONF_FILE}" 2>/dev/null; then
                log "Detected configuration change, updating..."

                # 复制新配置
                cp "${NGINX_CONFIG_DIR}/default.conf" "${NGINX_CONF_FILE}"

                # 测试配置
                if nginx -t; then
                    log "Configuration test passed, reloading Nginx..."
                    nginx -s reload
                    log "Nginx reloaded successfully"
                else
                    log "Configuration test failed, keeping old configuration"
                    # 恢复旧配置
                    git checkout "${NGINX_CONF_FILE}" 2>/dev/null || true
                fi
            fi
        fi

        # 检查重载信号
        if [ -f "${SHARED_CONFIG_DIR}/reload_nginx" ]; then
            log "Received reload signal"
            rm -f "${SHARED_CONFIG_DIR}/reload_nginx"

            if nginx -t; then
                nginx -s reload
                log "Nginx reloaded via signal"
            else
                log "Configuration test failed, skipping reload"
            fi
        fi

        sleep "${RELOAD_CHECK_INTERVAL}"
    done
}

# 健康检查函数
health_check() {
    # 检查Nginx进程
    if ! pgrep nginx >/dev/null; then
        log "Nginx process not found"
        return 1
    fi

    # 检查监听端口
    if ! ss -tlnp | grep -q ":{{ .Values.proxy.ports.http }} "; then
        log "Nginx not listening on HTTP port"
        return 1
    fi

{{- if .Values.proxy.ssl.enabled }}
    if ! ss -tlnp | grep -q ":{{ .Values.proxy.ports.https }} "; then
        log "Nginx not listening on HTTPS port"
        return 1
    fi
{{- end }}

    return 0
}

# 主函数
main() {
    log "Starting Nginx proxy server..."

    # 创建必要的目录
    mkdir -p "${SHARED_CONFIG_DIR}" "${NGINX_CONFIG_DIR}"

    # 初始化SSL证书
    init_ssl_certificates

    # 生成基础配置
    generate_base_nginx_config
    load_initial_config

    # 测试配置
    if ! nginx -t; then
        log "Initial configuration test failed"
        exit 1
    fi

    # 启动配置监控(后台)
    monitor_config_updates &
    MONITOR_PID=$!

    # 启动Nginx
    log "Starting Nginx..."
    nginx -g 'daemon off;' &
    NGINX_PID=$!

    # 等待和健康检查循环
    wait_for_signal() {
        while true; do
            sleep 30
            
            # 健康检查
            if ! health_check; then
                log "Health check failed, restarting Nginx..."
                kill $NGINX_PID 2>/dev/null || true
                sleep 5
                nginx -g 'daemon off;' &
                NGINX_PID=$!
            fi
            
            # 检查Nginx进程是否还在运行
            if ! kill -0 $NGINX_PID 2>/dev/null; then
                log "Nginx process died, restarting..."
                nginx -g 'daemon off;' &
                NGINX_PID=$!
            fi
        done
    }

    # 信号处理
    cleanup() {
        log "Received termination signal, shutting down..."
        kill $NGINX_PID $MONITOR_PID 2>/dev/null || true
        nginx -s quit 2>/dev/null || true
        exit 0
    }
    
    trap cleanup TERM INT

    # 等待信号或进程结束
    wait_for_signal
}

# 运行主函数
main "$@"