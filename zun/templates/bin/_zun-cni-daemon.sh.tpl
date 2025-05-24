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

# Create necessary directories
mkdir -p /var/log/zun
mkdir -p /var/lib/zun

echo "=== Starting Zun CNI Daemon ==="

# Check CNI configuration
{{- if and (eq .Values.network.driver "cni") .Values.conf.zun.cni_daemon.zun_cni_config_file }}
CNI_CONFIG_FILE="{{ .Values.conf.zun.cni_daemon.zun_cni_config_file }}"
if [ -f "$CNI_CONFIG_FILE" ]; then
    echo "CNI config found at: $CNI_CONFIG_FILE"
    cat "$CNI_CONFIG_FILE"
else
    echo "Warning: CNI config not found at: $CNI_CONFIG_FILE"
fi
{{- else }}
echo "Warning: CNI configuration not available or network driver is not CNI"
{{- end }}

# Check if running in Docker mode
{{- if .Values.conf.zun.cni_daemon.docker_mode }}
DOCKER_MODE="{{ .Values.conf.zun.cni_daemon.docker_mode }}"
if [ "$DOCKER_MODE" = "true" ]; then
    echo "Running in Docker mode"
    {{- if .Values.conf.zun.cni_daemon.netns_proc_dir }}
    NETNS_PROC_DIR="{{ .Values.conf.zun.cni_daemon.netns_proc_dir }}"
    if [ -n "$NETNS_PROC_DIR" ]; then
        echo "Network namespace proc dir: $NETNS_PROC_DIR"
        if [ -d "$NETNS_PROC_DIR" ]; then
            echo "✓ Network namespace proc directory accessible"
        else
            echo "⚠ Network namespace proc directory not accessible: $NETNS_PROC_DIR"
        fi
    fi
    {{- end }}
fi
{{- end }}

# Display configuration
echo ""
echo "CNI Daemon Configuration:"
{{- if .Values.conf.zun.cni_daemon.cni_daemon_host }}
echo "- Listen address: {{ .Values.conf.zun.cni_daemon.cni_daemon_host }}:{{ .Values.conf.zun.cni_daemon.cni_daemon_port }}"
{{- end }}
{{- if .Values.conf.zun.cni_daemon.worker_num }}
echo "- Worker processes: {{ .Values.conf.zun.cni_daemon.worker_num }}"
{{- end }}
{{- if .Values.conf.zun.cni_daemon.vif_active_timeout }}
echo "- VIF active timeout: {{ .Values.conf.zun.cni_daemon.vif_active_timeout }}s"
{{- end }}
{{- if .Values.conf.zun.cni_daemon.pyroute2_timeout }}
echo "- Pyroute2 timeout: {{ .Values.conf.zun.cni_daemon.pyroute2_timeout }}s"
{{- end }}

# Check CNI environment - using standard CNI approach
echo ""
echo "Checking CNI environment..."
echo "CNI daemon will receive network namespace paths via CNI_NETNS environment variable"
echo "Network namespaces are managed by kubelet, not directly accessed from /var/run/netns"

# Verify CNI binary and config directories
CNI_BIN_DIR="{{ .Values.network.drivers.cni.paths.bin_dir }}"
CNI_CONF_DIR="{{ .Values.network.drivers.cni.paths.conf_dir }}"

if [ -d "$CNI_BIN_DIR" ]; then
    echo "✓ CNI binary directory exists: $CNI_BIN_DIR"
    echo "Available CNI plugins:"
    ls -la "$CNI_BIN_DIR/" | grep -v "^total" || echo "No plugins found"
else
    echo "✗ CNI binary directory not found: $CNI_BIN_DIR"
fi

if [ -d "$CNI_CONF_DIR" ]; then
    echo "✓ CNI config directory exists: $CNI_CONF_DIR"
    echo "Available CNI configurations:"
    ls -la "$CNI_CONF_DIR/" | grep -v "^total" || echo "No configurations found"
else
    echo "✗ CNI config directory not found: $CNI_CONF_DIR"
fi

# SR-IOV configuration if enabled
{{- if .Values.conf.zun.cni_daemon.sriov_physnet_resource_mappings }}
echo ""
echo "SR-IOV Configuration:"
echo "- Physical network mappings: {{ .Values.conf.zun.cni_daemon.sriov_physnet_resource_mappings }}"
{{- if .Values.conf.zun.cni_daemon.sriov_resource_driver_mappings }}
echo "- Resource driver mappings: {{ .Values.conf.zun.cni_daemon.sriov_resource_driver_mappings }}"
{{- end }}
{{- end }}

echo ""
echo "Starting zun-cni-daemon..."
exec zun-cni-daemon \
    --config-file /etc/zun/zun.conf