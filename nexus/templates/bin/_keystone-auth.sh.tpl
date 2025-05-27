#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
使用helm-toolkit标准方式进行OpenStack认证
*/}}

set -eo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] KEYSTONE-AUTH: $*"
}

error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# 加载认证环境变量
source_keystone_auth() {
    local auth_type="${1:-admin}"  # admin 或 nexus

    log "Loading Keystone authentication for: ${auth_type}"

    # 从Secret中读取认证信息
    if [ -d "/tmp/keystone-secrets" ]; then
        if [ -f "/tmp/keystone-secrets/OS_AUTH_URL" ]; then
            export OS_AUTH_URL=$(cat /tmp/keystone-secrets/OS_AUTH_URL)
        fi

        if [ -f "/tmp/keystone-secrets/USERNAME" ]; then
            export OS_USERNAME=$(cat /tmp/keystone-secrets/USERNAME)
        fi

        if [ -f "/tmp/keystone-secrets/PASSWORD" ]; then
            export OS_PASSWORD=$(cat /tmp/keystone-secrets/PASSWORD)
        fi

        if [ -f "/tmp/keystone-secrets/PROJECT_NAME" ]; then
            export OS_PROJECT_NAME=$(cat /tmp/keystone-secrets/PROJECT_NAME)
        fi

        if [ -f "/tmp/keystone-secrets/USER_DOMAIN_NAME" ]; then
            export OS_USER_DOMAIN_NAME=$(cat /tmp/keystone-secrets/USER_DOMAIN_NAME)
        fi

        if [ -f "/tmp/keystone-secrets/PROJECT_DOMAIN_NAME" ]; then
            export OS_PROJECT_DOMAIN_NAME=$(cat /tmp/keystone-secrets/PROJECT_DOMAIN_NAME)
        fi

        if [ -f "/tmp/keystone-secrets/REGION_NAME" ]; then
            export OS_REGION_NAME=$(cat /tmp/keystone-secrets/REGION_NAME)
        fi

        if [ -f "/tmp/keystone-secrets/OS_IDENTITY_API_VERSION" ]; then
            export OS_IDENTITY_API_VERSION=$(cat /tmp/keystone-secrets/OS_IDENTITY_API_VERSION)
        else
            export OS_IDENTITY_API_VERSION=3
        fi
    else
        # 使用helm-toolkit标准方式获取环境变量
        {{- $userDetails := .Values.endpoints.identity.auth.admin }}
        export OS_AUTH_URL="${OS_AUTH_URL:-{{ tuple "identity" "internal" "api" . | include "helm-toolkit.endpoints.keystone_endpoint_uri_lookup" }}}"
        export OS_USERNAME="${OS_USERNAME:-{{ $userDetails.username }}}"
        export OS_PASSWORD="${OS_PASSWORD:-{{ $userDetails.password }}}"
        export OS_PROJECT_NAME="${OS_PROJECT_NAME:-{{ $userDetails.project_name }}}"
        export OS_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME:-{{ $userDetails.user_domain_name }}}"
        export OS_PROJECT_DOMAIN_NAME="${OS_PROJECT_DOMAIN_NAME:-{{ $userDetails.project_domain_name }}}"
        export OS_REGION_NAME="${OS_REGION_NAME:-{{ $userDetails.region_name }}}"
        export OS_IDENTITY_API_VERSION=3
    fi

    log "Authentication environment configured"
    log "  Auth URL: ${OS_AUTH_URL}"
    log "  Username: ${OS_USERNAME}"
    log "  Project: ${OS_PROJECT_NAME}"
    log "  Region: ${OS_REGION_NAME}"
}

# 验证OpenStack连接
verify_keystone_connection() {
    log "Verifying OpenStack connection..."

    # 检查必需的环境变量
    local required_vars=("OS_AUTH_URL" "OS_USERNAME" "OS_PASSWORD" "OS_PROJECT_NAME")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            error_exit "Required environment variable ${var} is not set"
        fi
    done

    # 尝试获取token
    if ! timeout 30 openstack token issue >/dev/null 2>&1; then
        error_exit "Failed to authenticate with OpenStack Keystone"
    fi

    log "OpenStack authentication successful"
}

# 使用OpenStack CLI获取服务端点
get_openstack_endpoints() {
    log "Retrieving OpenStack service endpoints..."

    local output_file="${1:-/tmp/openstack_endpoints.json}"

    if ! openstack endpoint list -f json > "${output_file}"; then
        error_exit "Failed to retrieve OpenStack endpoints"
    fi

    local endpoint_count=$(jq '.| length' "${output_file}" 2>/dev/null || echo "0")
    log "Retrieved ${endpoint_count} OpenStack endpoints"

    return 0
}

# 获取服务目录
get_service_catalog() {
    log "Retrieving OpenStack service catalog..."

    local output_file="${1:-/tmp/service_catalog.json}"

    if ! openstack catalog list -f json > "${output_file}"; then
        error_exit "Failed to retrieve service catalog"
    fi

    local service_count=$(jq '.| length' "${output_file}" 2>/dev/null || echo "0")
    log "Retrieved ${service_count} services from catalog"

    return 0
}

# 测试特定服务的可达性
test_service_connectivity() {
    local service_name="$1"
    local endpoint_type="${2:-public}"

    log "Testing connectivity to ${service_name} (${endpoint_type})..."

    # 获取服务端点URL
    local service_url
    case "${service_name}" in
        "keystone"|"identity")
            service_url=$(openstack catalog show identity -f value -c endpoints | grep "${endpoint_type}" | awk '{print $2}' | head -1)
            ;;
        "nova"|"compute")
            service_url=$(openstack catalog show compute -f value -c endpoints | grep "${endpoint_type}" | awk '{print $2}' | head -1)
            ;;
        "neutron"|"network")
            service_url=$(openstack catalog show network -f value -c endpoints | grep "${endpoint_type}" | awk '{print $2}' | head -1)
            ;;
        *)
            service_url=$(openstack catalog show "${service_name}" -f value -c endpoints | grep "${endpoint_type}" | awk '{print $2}' | head -1 2>/dev/null || true)
            ;;
    esac

    if [ -z "${service_url}" ]; then
        log "Could not find ${endpoint_type} endpoint for ${service_name}"
        return 1
    fi

    log "Testing URL: ${service_url}"

    # 测试HTTP连接
    if curl -s -f --connect-timeout 10 --max-time 30 "${service_url}" >/dev/null 2>&1; then
        log "Service ${service_name} is reachable"
        return 0
    else
        log "Service ${service_name} is not reachable"
        return 1
    fi
}

# 主函数
main() {
    local action="${1:-verify}"
    local auth_type="${2:-admin}"

    case "${action}" in
        "source"|"load")
            source_keystone_auth "${auth_type}"
            ;;
        "verify"|"test")
            source_keystone_auth "${auth_type}"
            verify_keystone_connection
            ;;
        "endpoints")
            source_keystone_auth "${auth_type}"
            verify_keystone_connection
            get_openstack_endpoints "$3"
            ;;
        "catalog")
            source_keystone_auth "${auth_type}"
            verify_keystone_connection
            get_service_catalog "$3"
            ;;
        "test-service")
            local service_name="$3"
            local endpoint_type="${4:-public}"
            if [ -z "${service_name}" ]; then
                echo "Usage: $0 test-service <auth_type> <service_name> [endpoint_type]" >&2
                exit 1
            fi
            source_keystone_auth "${auth_type}"
            verify_keystone_connection
            test_service_connectivity "${service_name}" "${endpoint_type}"
            ;;
        *)
            echo "Usage: $0 {source|verify|endpoints|catalog|test-service} [auth_type] [options...]" >&2
            echo "  source      - Load authentication environment variables"
            echo "  verify      - Verify OpenStack connection"
            echo "  endpoints   - Get endpoint list and save to file"
            echo "  catalog     - Get service catalog and save to file"
            echo "  test-service - Test connectivity to a specific service"
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"