#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
*/}}

set -eo pipefail

SHARED_CONFIG_DIR="/shared/config"
INITIAL_CONFIG_DIR="/tmp/initial-config"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INIT: $*"
}

main() {
    log "Initializing shared configuration..."

    # 确保共享配置目录存在
    mkdir -p "${SHARED_CONFIG_DIR}/nginx" "${SHARED_CONFIG_DIR}/dnsmasq"

    # 如果配置不存在，复制初始配置
    if [ ! -f "${SHARED_CONFIG_DIR}/nginx/default.conf" ]; then
        log "Copying initial nginx configuration..."
        cp "${INITIAL_CONFIG_DIR}/nginx-default.conf" "${SHARED_CONFIG_DIR}/nginx/default.conf"
    fi

    if [ ! -f "${SHARED_CONFIG_DIR}/dnsmasq/openstack.conf" ]; then
        log "Copying initial dnsmasq configuration..."
        cp "${INITIAL_CONFIG_DIR}/dnsmasq-default.conf" "${SHARED_CONFIG_DIR}/dnsmasq/openstack.conf"
    fi

    # 设置权限
    chmod -R 644 "${SHARED_CONFIG_DIR}"
    find "${SHARED_CONFIG_DIR}" -type d -exec chmod 755 {} \;

    log "Configuration initialization completed"
}

main "$@"