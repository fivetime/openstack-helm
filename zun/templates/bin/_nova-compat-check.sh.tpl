#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -ex

# 检查与 Nova 的兼容性和共享配置

echo "=== Nova Compatibility Check ==="

HOST_SHARED="{{ .Values.conf.zun.compute.host_shared_with_nova }}"

if [ "$HOST_SHARED" = "true" ]; then
    echo "This node is configured to be shared with Nova"

    # 检查 Nova compute 服务
    echo "Checking for nova-compute service..."
    if pgrep -f nova-compute > /dev/null; then
        echo "✓ nova-compute is running"
    else
        echo "⚠ nova-compute not found - this is expected if Nova runs in a container"
    fi

    # 检查 libvirt
    echo "Checking for libvirt..."
    if systemctl is-active libvirtd >/dev/null 2>&1; then
        echo "✓ libvirtd is active"
    elif pgrep -f libvirtd > /dev/null; then
        echo "✓ libvirtd process found"
    else
        echo "⚠ libvirtd not found - VMs and containers won't share CPU/memory properly"
    fi

    # 检查 Placement API 连接
    echo "Checking Placement API connectivity..."
    PLACEMENT_ENDPOINT="{{ tuple "placement" "internal" "api" . | include "helm-toolkit.endpoints.keystone_endpoint_uri_lookup" }}"

    # 使用 curl 测试 Placement API（需要认证）
    # 这里只是检查端口是否可达
    if curl -s --connect-timeout 5 "$PLACEMENT_ENDPOINT" >/dev/null 2>&1; then
        echo "✓ Placement API is reachable at $PLACEMENT_ENDPOINT"
    else
        echo "✗ Cannot reach Placement API at $PLACEMENT_ENDPOINT"
    fi

    # 检查资源预留配置
    echo ""
    echo "Resource reservation configuration:"
    echo "- Reserved memory: {{ .Values.conf.zun.compute.reserved_host_memory_mb }} MB"
    echo "- Reserved CPUs: {{ .Values.conf.zun.compute.reserved_host_cpus }}"
    echo "- Reserved disk: {{ .Values.conf.zun.compute.reserved_host_disk_mb }} MB"

    # 检查 CPU 分配
    echo ""
    echo "CPU configuration:"
    TOTAL_CPUS=$(nproc)
    RESERVED_CPUS="{{ .Values.conf.zun.compute.reserved_host_cpus }}"
    AVAILABLE_CPUS=$((TOTAL_CPUS - RESERVED_CPUS))

    echo "- Total CPUs: $TOTAL_CPUS"
    echo "- Reserved CPUs: $RESERVED_CPUS"
    echo "- Available for containers: $AVAILABLE_CPUS"

    {{- if .Values.conf.zun.compute.enable_cpu_pinning }}
    echo "- CPU pinning: enabled"
    {{- if .Values.conf.zun.compute.floating_cpu_set }}
    echo "- Floating CPU set: {{ .Values.conf.zun.compute.floating_cpu_set }}"
    {{- end }}
    {{- else }}
    echo "- CPU pinning: disabled"
    {{- end }}

    # 检查内存
    echo ""
    echo "Memory configuration:"
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    RESERVED_MEM="{{ .Values.conf.zun.compute.reserved_host_memory_mb }}"
    AVAILABLE_MEM=$((TOTAL_MEM - RESERVED_MEM))

    echo "- Total memory: $TOTAL_MEM MB"
    echo "- Reserved memory: $RESERVED_MEM MB"
    echo "- Available for containers: $AVAILABLE_MEM MB"

else
    echo "This node is NOT shared with Nova (standalone Zun)"
fi

# 检查调度器配置
echo ""
echo "=== Scheduler Configuration ==="
echo "Driver: {{ .Values.conf.zun.scheduler.driver }}"
echo "Enabled filters: {{ .Values.conf.zun.scheduler.enabled_filters }}"

# 检查聚合和可用区
echo ""
echo "=== Availability Zone ==="
echo "Default AZ: {{ .Values.conf.zun.DEFAULT.default_availability_zone }}"

echo ""
echo "=== Check Complete ==="