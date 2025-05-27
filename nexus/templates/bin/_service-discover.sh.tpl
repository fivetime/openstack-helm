#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
*/}}

set -eo pipefail

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DISCOVER: $*"
}

error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# 检查kubectl连接
check_kubectl() {
    if ! kubectl version --client &>/dev/null; then
        error_exit "kubectl not available"
    fi

    if ! kubectl get namespace "${OPENSTACK_NAMESPACE}" &>/dev/null; then
        error_exit "Cannot access namespace: ${OPENSTACK_NAMESPACE}"
    fi

    log "kubectl connection verified"
}

# 发现Kubernetes服务
discover_k8s_services() {
    log "Discovering Kubernetes services in namespace: ${OPENSTACK_NAMESPACE}"

    if ! kubectl -n "${OPENSTACK_NAMESPACE}" get svc -o json > "${OUTPUT_FILE}"; then
        error_exit "Failed to get services from Kubernetes"
    fi

    local service_count=$(jq '.items | length' "${OUTPUT_FILE}")
    log "Discovered ${service_count} Kubernetes services"
}

# 发现OpenStack端点 (如果启用了OpenStack CLI)
discover_openstack_endpoints() {
    if [ "${USE_OPENSTACK_CLI:-false}" = "true" ]; then
        log "Discovering OpenStack endpoints via CLI..."

        # 加载认证环境变量
        if [ -f "/tmp/keystone-secrets/OS_AUTH_URL" ]; then
            export OS_AUTH_URL=$(cat /tmp/keystone-secrets/OS_AUTH_URL)
            export OS_USERNAME=$(cat /tmp/keystone-secrets/USERNAME)
            export OS_PASSWORD=$(cat /tmp/keystone-secrets/PASSWORD)
            export OS_PROJECT_NAME=$(cat /tmp/keystone-secrets/PROJECT_NAME)
            export OS_USER_DOMAIN_NAME=$(cat /tmp/keystone-secrets/USER_DOMAIN_NAME)
            export OS_PROJECT_DOMAIN_NAME=$(cat /tmp/keystone-secrets/PROJECT_DOMAIN_NAME)
            export OS_IDENTITY_API_VERSION=$(cat /tmp/keystone-secrets/OS_IDENTITY_API_VERSION)
        fi

        if timeout 30 openstack endpoint list -f json > "${OUTPUT_FILE}.openstack" 2>/dev/null; then
            log "OpenStack endpoints discovered successfully"
        else
            log "Failed to discover OpenStack endpoints, continuing with Kubernetes only"
        fi
    fi
}

# 获取代理目标地址
get_proxy_target() {
    local target=""

    # 尝试获取LoadBalancer IP
    log "Looking for service: ${PUBLIC_SERVICE_NAME}"
    local lb_ip=$(kubectl -n "${OPENSTACK_NAMESPACE}" get svc "${PUBLIC_SERVICE_NAME}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [ -n "${lb_ip}" ] && [ "${lb_ip}" != "null" ]; then
        target="${lb_ip}"
        log "Found LoadBalancer IP: ${target}"
    else
        # 尝试获取ClusterIP
        local cluster_ip=$(kubectl -n "${OPENSTACK_NAMESPACE}" get svc "${PUBLIC_SERVICE_NAME}" \
            -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

        if [ -n "${cluster_ip}" ] && [ "${cluster_ip}" != "null" ] && [ "${cluster_ip}" != "None" ]; then
            target="${cluster_ip}"
            log "Found ClusterIP: ${target}"
        else
            target="${FALLBACK_TARGET}"
            log "Using fallback target: ${target}"
        fi
    fi

    echo "${target}"
}

# 主函数
main() {
    # 必需的环境变量
    OPENSTACK_NAMESPACE="${OPENSTACK_NAMESPACE:-openstack}"
    PUBLIC_SERVICE_NAME="${PUBLIC_SERVICE_NAME:-public-openstack}"
    FALLBACK_TARGET="${FALLBACK_TARGET:-127.0.0.1}"
    OUTPUT_FILE="${OUTPUT_FILE:-/tmp/services.json}"

    log "Starting service discovery..."
    log "Namespace: ${OPENSTACK_NAMESPACE}"
    log "Public service: ${PUBLIC_SERVICE_NAME}"
    log "Fallback target: ${FALLBACK_TARGET}"

    check_kubectl
    discover_k8s_services
    discover_openstack_endpoints

    # 获取并输出代理目标
    local proxy_target=$(get_proxy_target)
    echo "${proxy_target}" > "${OUTPUT_FILE}.proxy_target"

    log "Service discovery completed. Target: ${proxy_target}"
}

main "$@"