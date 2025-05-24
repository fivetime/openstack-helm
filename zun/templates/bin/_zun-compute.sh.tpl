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
mkdir -p /var/lib/zun/tmp

# Container runtime detection and setup
CONTAINER_RUNTIME="{{ .Values.container_runtime.type }}"

echo "=== Container Runtime Configuration ==="
echo "Configured runtime: $CONTAINER_RUNTIME"

{{- if eq .Values.container_runtime.type "docker" }}
# Docker runtime setup
DOCKER_SOCKET="{{ .Values.container_runtime.docker.socket_path }}"

# Find Docker socket
if [ ! -S "$DOCKER_SOCKET" ]; then
    echo "Error: Docker socket not found at $DOCKER_SOCKET"
    echo "Checking alternative locations..."

    if [ -S /var/run/docker.sock ]; then
        DOCKER_SOCKET="/var/run/docker.sock"
    elif [ -S /run/docker.sock ]; then
        DOCKER_SOCKET="/run/docker.sock"
    else
        echo "Error: No Docker socket found"
        exit 1
    fi
fi

echo "Found Docker socket at: $DOCKER_SOCKET"
export DOCKER_HOST="unix://$DOCKER_SOCKET"

# Test Docker connectivity
echo "Testing Docker connectivity..."
if timeout 10 docker version 2>&1; then
    echo "✓ Docker connectivity verified"
    docker version | head -5
else
    echo "✗ Docker connectivity failed"
    echo "Debug information:"
    echo "- Socket permissions: $(ls -la $DOCKER_SOCKET)"
    echo "- Current user: $(id)"

    # Try to fix permissions with more secure approach
    echo "Attempting to fix socket permissions..."
    # Use 660 instead of 666 for better security (group readable/writable, not world)
    if chmod 660 $DOCKER_SOCKET 2>/dev/null; then
        echo "✓ Fixed socket permissions (660)"

        # Try again after permission fix
        if timeout 10 docker version >/dev/null 2>&1; then
            echo "✓ Docker connectivity restored"
        else
            echo "✗ Docker still not accessible after permission fix"

            # Last resort: check if we need to be in docker group
            DOCKER_GROUP="{{ .Values.container_runtime.docker.socket_group | default "docker" }}"
            echo "Checking Docker group membership for group: $DOCKER_GROUP"

            if getent group "$DOCKER_GROUP" >/dev/null 2>&1; then
                echo "Docker group exists, but connectivity still failed"
                echo "This might be expected in containerized environments"
            else
                echo "Docker group not found: $DOCKER_GROUP"
            fi

            echo "Continuing with limited Docker access..."
        fi
    else
        echo "✗ Could not fix socket permissions, continuing anyway..."
    fi
fi

{{- else if eq .Values.container_runtime.type "cri" }}
# CRI runtime setup
CRI_SOCKET="{{ .Values.container_runtime.cri.socket_path }}"

if [ ! -S "$CRI_SOCKET" ]; then
    echo "Error: CRI socket not found at $CRI_SOCKET"
    exit 1
fi

echo "Found CRI socket at: $CRI_SOCKET"

# Test CRI connectivity using crictl
if command -v crictl >/dev/null 2>&1; then
    export CONTAINER_RUNTIME_ENDPOINT="unix://$CRI_SOCKET"
    echo "Testing CRI connectivity..."
    if timeout 10 crictl version 2>&1; then
        echo "✓ CRI connectivity verified"
        crictl version
    else
        echo "✗ CRI connectivity failed"
        echo "Continuing anyway, as this might be expected during startup..."
    fi
else
    echo "Warning: crictl not found, cannot test CRI connectivity"
fi
{{- end }}

# Network driver detection
NETWORK_DRIVER="{{ .Values.network.driver }}"
echo ""
echo "=== Network Configuration ==="
echo "Network driver: $NETWORK_DRIVER"

{{- if eq .Values.network.driver "kuryr" }}
# Check for Kuryr network driver
if [ "$CONTAINER_RUNTIME" = "docker" ]; then
    echo "Checking for Kuryr network driver..."
    if timeout 10 docker network ls 2>/dev/null; then
        if docker network ls --format "table {{`{{.Driver}}`}}" 2>/dev/null | grep -q kuryr; then
            echo "✓ Kuryr network driver is available"
            docker network ls | grep kuryr
        else
            echo "⚠ Kuryr network driver not found"
            echo "Available network drivers:"
            docker network ls --format "table {{`{{.Name}}`}}\t{{`{{.Driver}}`}}" 2>/dev/null || echo "Could not list drivers"
        fi
    else
        echo "⚠ Could not list Docker networks"
    fi
fi

{{- else if eq .Values.network.driver "cni" }}
# Check for CNI setup
echo "Checking CNI configuration..."
CNI_CONF_DIR="{{ .Values.network.drivers.cni.paths.conf_dir }}"
CNI_BIN_DIR="{{ .Values.network.drivers.cni.paths.bin_dir }}"

echo "CNI directories:"
echo "- Config dir: $CNI_CONF_DIR"
echo "- Binary dir: $CNI_BIN_DIR"

if [ -f "$CNI_CONF_DIR/10-zun-cni.conf" ]; then
    echo "✓ CNI config found"
    echo "CNI Configuration:"
    cat "$CNI_CONF_DIR/10-zun-cni.conf"
else
    echo "⚠ CNI config not found at $CNI_CONF_DIR/10-zun-cni.conf"
    echo "Available configs:"
    ls -la "$CNI_CONF_DIR/" 2>/dev/null || echo "Config directory not accessible"
fi

if [ -f "$CNI_BIN_DIR/zun-cni" ]; then
    echo "✓ zun-cni binary found"
    ls -la "$CNI_BIN_DIR/zun-cni"
else
    echo "⚠ zun-cni binary not found at $CNI_BIN_DIR/zun-cni"
    echo "Available CNI binaries:"
    ls -la "$CNI_BIN_DIR/" 2>/dev/null || echo "Binary directory not accessible"
fi
{{- end }}

# Image driver check
echo ""
echo "=== Image Driver Configuration ==="
echo "Image drivers: {{ join ", " .Values.image_driver.driver_list }}"
echo "Default driver: {{ .Values.image_driver.default }}"

{{- if has "glance" .Values.image_driver.driver_list }}
# Check Glance image directory
GLANCE_IMAGE_DIR="{{ .Values.conf.zun.glance.images_directory }}"
if [ -d "$GLANCE_IMAGE_DIR" ]; then
    echo "✓ Glance image directory exists: $GLANCE_IMAGE_DIR"
else
    echo "⚠ Creating Glance image directory: $GLANCE_IMAGE_DIR"
    mkdir -p "$GLANCE_IMAGE_DIR" || echo "Failed to create Glance image directory"
fi
{{- end }}

# Volume driver check
echo ""
echo "=== Volume Driver Configuration ==="
echo "Volume drivers: {{ join ", " .Values.volume_driver.driver_list }}"

{{- if has "local" .Values.volume_driver.driver_list }}
# Check local volume directory
VOLUME_DIR="{{ .Values.volume_driver.volume_dir }}"
if [ -d "$VOLUME_DIR" ]; then
    echo "✓ Volume directory exists: $VOLUME_DIR"
else
    echo "⚠ Creating volume directory: $VOLUME_DIR"
    mkdir -p "$VOLUME_DIR" || echo "Failed to create volume directory"
fi
{{- end }}

# Final connectivity test before starting service
echo ""
echo "=== Pre-startup Validation ==="

# Test container runtime one more time
case "$CONTAINER_RUNTIME" in
    docker)
        if timeout 5 docker info >/dev/null 2>&1; then
            echo "✓ Docker runtime ready"
        else
            echo "⚠ Docker runtime not fully ready, but proceeding..."
        fi
        ;;
    cri)
        if command -v crictl >/dev/null 2>&1 && timeout 5 crictl info >/dev/null 2>&1; then
            echo "✓ CRI runtime ready"
        else
            echo "⚠ CRI runtime not fully ready, but proceeding..."
        fi
        ;;
esac

echo ""
echo "=== Starting zun-compute ==="
exec zun-compute \
    --config-file /etc/zun/zun.conf