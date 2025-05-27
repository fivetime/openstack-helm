#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
*/}}

set -eo pipefail

# 工作目录
WORK_DIR="/tmp/service-discovery"
SHARED_CONFIG_DIR="/shared/config"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ORCHESTRATOR: $*"
}

error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# 初始化工作环境
init_environment() {
    log "Initializing service discovery environment..."

    # 创建工作目录
    mkdir -p "${WORK_DIR}"

    # 设置环境变量
    export OPENSTACK_NAMESPACE="${OPENSTACK_NAMESPACE:-openstack}"
    export PUBLIC_SERVICE_NAME="${PUBLIC_SERVICE_NAME:-public-openstack}"
    export FALLBACK_TARGET="${FALLBACK_TARGET:-127.0.0.1}"
    export OUTPUT_FILE="${WORK_DIR}/services.json"
    export USE_OPENSTACK_CLI="${USE_OPENSTACK_CLI:-false}"

    log "Environment initialized"
    log "  Namespace: ${OPENSTACK_NAMESPACE}"
    log "  Public service: ${PUBLIC_SERVICE_NAME}"
    log "  Fallback target: ${FALLBACK_TARGET}"
    log "  OpenStack CLI: ${USE_OPENSTACK_CLI}"
}

# 执行服务发现
run_discovery() {
    log "Running service discovery..."

    if ! /tmp/discover-services.sh; then
        error_exit "Service discovery failed"
    fi

    if [ ! -f "${OUTPUT_FILE}" ] || [ ! -f "${OUTPUT_FILE}.proxy_target" ]; then
        error_exit "Service discovery output files not found"
    fi

    local service_count=$(jq '.items | length' "${OUTPUT_FILE}" 2>/dev/null || echo "0")
    local proxy_target=$(cat "${OUTPUT_FILE}.proxy_target")

    log "Service discovery completed:"
    log "  Services found: ${service_count}"
    log "  Proxy target: ${proxy_target}"
}

# 生成配置文件
generate_configurations() {
    log "Generating configuration files..."

    local nginx_config="${WORK_DIR}/nginx-default.conf"
    local dns_config="${WORK_DIR}/dnsmasq-openstack.conf"

    # 生成Nginx配置
    if ! /tmp/generate-nginx-config.sh "${OUTPUT_FILE}" "${OUTPUT_FILE}.proxy_target" "${nginx_config}"; then
        error_exit "Failed to generate Nginx configuration"
    fi

    # 生成DNS配置
    if ! /tmp/generate-dns-config.sh "${OUTPUT_FILE}" "${OUTPUT_FILE}.proxy_target" "${dns_config}"; then
        error_exit "Failed to generate DNS configuration"
    fi

    log "Configuration files generated successfully"
}

# 应用配置更改
apply_configurations() {
    log "Applying configuration changes..."

    local nginx_config="${WORK_DIR}/nginx-default.conf"
    local dns_config="${WORK_DIR}/dnsmasq-openstack.conf"
    local update_count=0

    # 应用Nginx配置
    if /tmp/config-manager.sh write "${nginx_config}" "nginx" "default"; then
        log "Nginx configuration updated"
        ((update_count++))
    else
        log "Nginx configuration update failed or skipped"
    fi

    # 应用DNS配置
    if /tmp/config-manager.sh write "${dns_config}" "dnsmasq" "openstack"; then
        log "DNS configuration updated"
        ((update_count++))
    else
        log "DNS configuration update failed or skipped"
    fi

    log "Configuration application completed (${update_count} updates)"
}

# 生成摘要报告
generate_summary() {
    log "Generating discovery summary..."

    local summary_file="${SHARED_CONFIG_DIR}/discovery-summary.json"
    local proxy_target=$(cat "${OUTPUT_FILE}.proxy_target" 2>/dev/null || echo "unknown")
    local service_count=$(jq '.items | length' "${OUTPUT_FILE}" 2>/dev/null || echo "0")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # 提取服务名称列表
    local services_list=$(jq -r '.items[].metadata.name' "${OUTPUT_FILE}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')

    cat > "${summary_file}" << EOF
{
    "timestamp": "${timestamp}",
    "discovery": {
        "namespace": "${OPENSTACK_NAMESPACE}",
        "proxy_target": "${proxy_target}",
        "service_count": ${service_count},
        "services": ${services_list}
    },
    "configuration": {
        "nginx_updated": $([ -f "${SHARED_CONFIG_DIR}/reload_nginx" ] && echo "true" || echo "false"),
        "dns_updated": $([ -f "${SHARED_CONFIG_DIR}/reload_dnsmasq" ] && echo "true" || echo "false")
    }
}
EOF

    log "Summary generated: ${summary_file}"
}

# 清理工作目录
cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "${WORK_DIR}"
}

# 主函数
main() {
    log "Starting OpenStack service discovery orchestration..."

    # 设置清理陷阱
    trap cleanup EXIT

    # 执行服务发现流程
    init_environment
    run_discovery
    generate_configurations
    apply_configurations
    generate_summary

    log "Service discovery orchestration completed successfully"
}

# 运行主函数
main "$@"