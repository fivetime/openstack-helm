#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
*/}}

set -eo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS-GEN: $*"
}

# 生成DNS配置
generate_dns_config() {
    local services_json="$1"
    local proxy_target="$2"
    local output_file="$3"

    log "Generating DNS configuration for target: ${proxy_target}"

    local service_count=$(jq '.items | length' "${services_json}")

    cat > "${output_file}" << EOF
# OpenStack DNS代理配置
# 自动生成于 $(date)
# 代理目标: ${proxy_target}
# 服务数量: ${service_count}

# 基础配置
port=53
domain-needed
bogus-priv
no-resolv
no-poll

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
log-facility=-
{{- end }}

# OpenStack服务域名解析
# 通配符域名
address=/.${OPENSTACK_NAMESPACE}.svc.cluster.local/${proxy_target}
address=/.${OPENSTACK_NAMESPACE}.svc/${proxy_target}
address=/.${OPENSTACK_NAMESPACE}/${proxy_target}
EOF

    # 添加具体服务域名
    jq -r '.items[].metadata.name' "${services_json}" | while read -r service; do
        [ -z "$service" ] && continue
        cat >> "${output_file}" << EOF
address=/${service}/${proxy_target}
address=/${service}.${OPENSTACK_NAMESPACE}/${proxy_target}
address=/${service}.${OPENSTACK_NAMESPACE}.svc/${proxy_target}
address=/${service}.${OPENSTACK_NAMESPACE}.svc.cluster.local/${proxy_target}
EOF
    done

    cat >> "${output_file}" << EOF

{{- if .Values.dns.forward_zones }}
# 自定义转发区域
{{- range .Values.dns.forward_zones }}
{{- range .servers }}
server=/{{ $.zone }}/{{ . }}
{{- end }}
{{- end }}
{{- end }}

# 监听配置
bind-interfaces
interface=*
EOF

    log "DNS configuration generated successfully"
}

# 主函数
main() {
    local services_json="${1:-/tmp/services.json}"
    local proxy_target_file="${2:-/tmp/services.json.proxy_target}"
    local output_file="${3:-/tmp/dns-config.conf}"

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

    generate_dns_config "${services_json}" "${proxy_target}" "${output_file}"
}

main "$@"