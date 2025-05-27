#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
*/}}

set -eo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NGINX-GEN: $*"
}

# 生成服务域名列表
generate_domain_list() {
    local services_json="$1"

    # 提取服务名称并生成所有可能的域名格式
    jq -r '.items[].metadata.name' "${services_json}" | while read -r service; do
        [ -z "$service" ] && continue
        echo "${service}"
        echo "${service}.${OPENSTACK_NAMESPACE}"
        echo "${service}.${OPENSTACK_NAMESPACE}.svc"
        echo "${service}.${OPENSTACK_NAMESPACE}.svc.cluster.local"
    done | sort -u
}

# 生成Nginx配置
generate_nginx_config() {
    local services_json="$1"
    local proxy_target="$2"
    local output_file="$3"

    log "Generating Nginx configuration for target: ${proxy_target}"

    # 生成域名列表
    local domains=$(generate_domain_list "${services_json}")
    local domain_count=$(echo "${domains}" | wc -l)

    cat > "${output_file}" << EOF
# OpenStack Nginx代理配置
# 自动生成于 $(date)
# 代理目标: ${proxy_target}
# 服务数量: ${domain_count}

# 健康检查端点
server {
    listen 8080;
    server_name _;

    location /nginx-health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }
}

# HTTP代理配置
server {
    listen {{ .Values.proxy.ports.http }} default_server;

    # 匹配所有OpenStack相关域名
    server_name
        # 通配符匹配
        ~^.*\\.${OPENSTACK_NAMESPACE}\\.svc\\.cluster\\.local\$
        ~^.*\\.${OPENSTACK_NAMESPACE}\\.svc\$
        ~^.*\\.${OPENSTACK_NAMESPACE}\$
EOF

    # 添加具体服务名称
    echo "${domains}" | while read -r domain; do
        [ -z "$domain" ] && continue
        # 跳过已经通过正则匹配的域名
        if [[ "${domain}" == *".${OPENSTACK_NAMESPACE}.svc.cluster.local" ]] || \
           [[ "${domain}" == *".${OPENSTACK_NAMESPACE}.svc" ]] || \
           [[ "${domain}" == *".${OPENSTACK_NAMESPACE}" ]]; then
            continue
        fi
        echo "        ${domain}" >> "${output_file}"
    done

    cat >> "${output_file}" << EOF
        _;  # 默认匹配

    # 日志配置
    access_log /var/log/nginx/openstack-access.log;
    error_log /var/log/nginx/openstack-error.log;

    # 代理配置
    location / {
        proxy_pass http://${proxy_target};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 超时配置
        proxy_connect_timeout {{ .Values.proxy.proxy_timeouts.connect }};
        proxy_send_timeout {{ .Values.proxy.proxy_timeouts.send }};
        proxy_read_timeout {{ .Values.proxy.proxy_timeouts.read }};

        # 大文件支持
        client_max_body_size {{ .Values.proxy.client_max_body_size }};

        # 缓冲配置
        proxy_buffering off;
        proxy_request_buffering off;
    }
}

{{- if .Values.proxy.ssl.enabled }}
# HTTPS代理配置
server {
    listen {{ .Values.proxy.ports.https }} ssl default_server;

    # SSL证书配置
    ssl_certificate /etc/nginx/ssl/tls.crt;
    ssl_certificate_key /etc/nginx/ssl/tls.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 匹配所有域名
    server_name _;

    # 日志配置
    access_log /var/log/nginx/openstack-ssl-access.log;
    error_log /var/log/nginx/openstack-ssl-error.log;

    # 代理配置
    location / {
        proxy_pass https://${proxy_target};
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 超时配置
        proxy_connect_timeout {{ .Values.proxy.proxy_timeouts.connect }};
        proxy_send_timeout {{ .Values.proxy.proxy_timeouts.send }};
        proxy_read_timeout {{ .Values.proxy.proxy_timeouts.read }};

        # 大文件支持
        client_max_body_size {{ .Values.proxy.client_max_body_size }};

        # 缓冲配置
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
{{- end }}
EOF

    log "Nginx configuration generated successfully"
}

# 主函数
main() {
    local services_json="${1:-/tmp/services.json}"
    local proxy_target_file="${2:-/tmp/services.json.proxy_target}"
    local output_file="${3:-/tmp/nginx-config.conf}"

    if [ ! -f "${services_json}" ]; then
        echo "Services JSON file not found: ${services_json}" >&2
        exit 1
    fi

    if [ ! -f "${proxy_target_file}" ]; then
        echo "Proxy target file not found: ${proxy_target_file}" >&2
        exit 1
    fi

    local proxy_target=$(cat "${proxy_target_file}")

    OPENSTACK_NAMESPACE="${OPENSTACK_NAMESPACE:-openstack}"

    generate_nginx_config "${services_json}" "${proxy_target}" "${output_file}"
}

main "$@"