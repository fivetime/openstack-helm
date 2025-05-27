#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
RBAC权限设置脚本
*/}}

set -eo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RBAC-SETUP: $*"
}

error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# 验证必需的环境变量
validate_environment() {
    if [ -z "${OPENSTACK_NAMESPACE}" ]; then
        error_exit "OPENSTACK_NAMESPACE environment variable is required"
    fi

    if [ -z "${CURRENT_NAMESPACE}" ]; then
        error_exit "CURRENT_NAMESPACE environment variable is required"
    fi

    log "Environment validated:"
    log "  OpenStack namespace: ${OPENSTACK_NAMESPACE}"
    log "  Current namespace: ${CURRENT_NAMESPACE}"
}

# 检查命名空间是否存在
check_namespace() {
    local namespace="$1"

    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        log "Warning: Namespace '${namespace}' does not exist"
        return 1
    fi

    return 0
}

# 验证服务账户权限
verify_service_account_permissions() {
    local sa_name="nexus-service-discovery"
    local namespace="${CURRENT_NAMESPACE}"

    log "Verifying service account permissions..."

    # 检查是否可以在OpenStack命名空间中获取服务
    if kubectl auth can-i get services \
        --as="system:serviceaccount:${namespace}:${sa_name}" \
        -n "${OPENSTACK_NAMESPACE}" >/dev/null 2>&1; then
        log "✓ Can get services in ${OPENSTACK_NAMESPACE}"
    else
        error_exit "✗ Cannot get services in ${OPENSTACK_NAMESPACE}"
    fi

    # 检查是否可以列出服务
    if kubectl auth can-i list services \
        --as="system:serviceaccount:${namespace}:${sa_name}" \
        -n "${OPENSTACK_NAMESPACE}" >/dev/null 2>&1; then
        log "✓ Can list services in ${OPENSTACK_NAMESPACE}"
    else
        error_exit "✗ Cannot list services in ${OPENSTACK_NAMESPACE}"
    fi

    # 检查是否可以获取端点
    if kubectl auth can-i get endpoints \
        --as="system:serviceaccount:${namespace}:${sa_name}" \
        -n "${OPENSTACK_NAMESPACE}" >/dev/null 2>&1; then
        log "✓ Can get endpoints in ${OPENSTACK_NAMESPACE}"
    else
        error_exit "✗ Cannot get endpoints in ${OPENSTACK_NAMESPACE}"
    fi

    # 检查是否可以获取命名空间信息
    if kubectl auth can-i get namespaces \
        --as="system:serviceaccount:${namespace}:${sa_name}" >/dev/null 2>&1; then
        log "✓ Can get namespace information"
    else
        error_exit "✗ Cannot get namespace information"
    fi

    log "All required permissions verified successfully"
}

# 测试服务发现功能
test_service_discovery() {
    log "Testing service discovery functionality..."

    # 检查OpenStack命名空间中是否有服务
    local service_count
    service_count=$(kubectl get svc -n "${OPENSTACK_NAMESPACE}" --no-headers 2>/dev/null | wc -l)

    if [ "${service_count}" -eq 0 ]; then
        log "Warning: No services found in ${OPENSTACK_NAMESPACE} namespace"
        log "This may be expected if OpenStack is not yet deployed"
    else
        log "Found ${service_count} services in ${OPENSTACK_NAMESPACE} namespace"

        # 列出前几个服务作为验证
        log "Sample services:"
        kubectl get svc -n "${OPENSTACK_NAMESPACE}" --no-headers | head -5 | while read line; do
            local svc_name=$(echo "${line}" | awk '{print $1}')
            log "  - ${svc_name}"
        done
    fi
}

# 验证集群角色和绑定
verify_cluster_rbac() {
    log "Verifying cluster-level RBAC configuration..."

    # 检查ClusterRole
    if kubectl get clusterrole nexus-service-discovery >/dev/null 2>&1; then
        log "✓ ClusterRole 'nexus-service-discovery' exists"
    else
        error_exit "✗ ClusterRole 'nexus-service-discovery' not found"
    fi

    # 检查ClusterRoleBinding
    if kubectl get clusterrolebinding nexus-service-discovery >/dev/null 2>&1; then
        log "✓ ClusterRoleBinding 'nexus-service-discovery' exists"
    else
        error_exit "✗ ClusterRoleBinding 'nexus-service-discovery' not found"
    fi

    # 验证绑定的正确性
    local expected_sa="system:serviceaccount:${CURRENT_NAMESPACE}:nexus-service-discovery"
    local actual_subjects
    actual_subjects=$(kubectl get clusterrolebinding nexus-service-discovery -o jsonpath='{.subjects[*].name}' 2>/dev/null || echo "")

    if echo "${actual_subjects}" | grep -q "nexus-service-discovery"; then
        log "✓ ClusterRoleBinding subjects configured correctly"
    else
        log "Warning: ClusterRoleBinding subjects may not be configured correctly"
        log "Expected: ${expected_sa}"
        log "Actual subjects: ${actual_subjects}"
    fi
}

# 执行完整的RBAC验证
run_rbac_verification() {
    log "Starting comprehensive RBAC verification..."

    validate_environment

    # 检查命名空间
    if ! check_namespace "${OPENSTACK_NAMESPACE}"; then
        log "Warning: OpenStack namespace not found, some tests will be skipped"
    fi

    if ! check_namespace "${CURRENT_NAMESPACE}"; then
        error_exit "Current namespace not found: ${CURRENT_NAMESPACE}"
    fi

    # 验证RBAC配置
    verify_cluster_rbac
    verify_service_account_permissions

    # 测试功能
    test_service_discovery

    log "RBAC verification completed successfully"
}

# 主函数
main() {
    log "Nexus RBAC Setup and Verification"
    log "================================="

    run_rbac_verification

    log "RBAC setup job completed successfully"
}

# 运行主函数
main "$@"