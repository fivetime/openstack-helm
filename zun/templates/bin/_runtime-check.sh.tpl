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

set -e

# This script checks the container runtime configuration
# and ensures all necessary components are available

RUNTIME_TYPE="{{ .Values.container_runtime.type }}"

echo "=== Container Runtime Check ==="
echo "Runtime type: $RUNTIME_TYPE"

check_docker() {
    echo ""
    echo "Checking Docker runtime..."
    local docker_ok=0

    # Check Docker socket
    DOCKER_SOCKET="{{ .Values.container_runtime.docker.socket_path }}"
    if [ -S "$DOCKER_SOCKET" ]; then
        echo "✓ Docker socket found: $DOCKER_SOCKET"
    else
        echo "✗ Docker socket not found: $DOCKER_SOCKET"
        return 1
    fi

    # Check if docker command is available
    if command -v docker >/dev/null 2>&1; then
        # Test Docker daemon connectivity with timeout
        if timeout 10 docker version >/dev/null 2>&1; then
            echo "✓ Docker daemon is running"
            docker version --format 'Server Version: {{`{{.Server.Version}}`}}' 2>/dev/null || echo "Could not get version details"
            docker_ok=1
        else
            echo "✗ Docker daemon is not accessible"
            echo "Troubleshooting:"
            echo "- Socket permissions: $(ls -la $DOCKER_SOCKET 2>/dev/null || echo 'cannot access socket')"
            echo "- Current user: $(id)"
        fi
    else
        echo "⚠ Docker command not available, but socket exists"
        echo "This may be normal in containerized environments"
    fi

    # Check Docker group (non-fatal)
    DOCKER_GROUP="{{ .Values.container_runtime.docker.socket_group }}"
    if getent group "$DOCKER_GROUP" >/dev/null 2>&1; then
        echo "✓ Docker group exists: $DOCKER_GROUP"
    else
        echo "⚠ Docker group not found: $DOCKER_GROUP (may be expected in containers)"
    fi

    return $([[ $docker_ok -eq 1 ]] && echo 0 || echo 1)
}

check_cri() {
    echo ""
    echo "Checking CRI runtime..."
    local cri_ok=0

    # Check CRI socket
    CRI_SOCKET="{{ .Values.container_runtime.cri.socket_path }}"
    if [ -S "$CRI_SOCKET" ]; then
        echo "✓ CRI socket found: $CRI_SOCKET"
    else
        echo "✗ CRI socket not found: $CRI_SOCKET"
        return 1
    fi

    # Check crictl if available
    if command -v crictl >/dev/null 2>&1; then
        export CONTAINER_RUNTIME_ENDPOINT="unix://$CRI_SOCKET"
        if timeout 10 crictl version >/dev/null 2>&1; then
            echo "✓ CRI runtime is accessible"
            crictl version 2>/dev/null || echo "Could not get detailed CRI version"
            cri_ok=1
        else
            echo "✗ CRI runtime is not accessible"
            echo "Troubleshooting:"
            echo "- Socket permissions: $(ls -la $CRI_SOCKET 2>/dev/null || echo 'cannot access socket')"
            echo "- Runtime endpoint: $CONTAINER_RUNTIME_ENDPOINT"
        fi
    else
        echo "⚠ crictl not found, cannot verify CRI runtime"
        echo "Assuming CRI runtime is available based on socket presence"
        cri_ok=1
    fi

    {{- if .Values.container_runtime.cri.kata.enabled }}
    # Check Kata Containers
    echo ""
    echo "Checking Kata Containers..."
    KATA_RUNTIME="{{ .Values.container_runtime.cri.kata.runtime_path }}"
    if [ -x "$KATA_RUNTIME" ]; then
        echo "✓ Kata runtime found: $KATA_RUNTIME"
        if timeout 5 $KATA_RUNTIME --version >/dev/null 2>&1; then
            $KATA_RUNTIME --version 2>/dev/null || echo "Kata version check failed"
        else
            echo "⚠ Kata runtime found but not responding"
        fi
    else
        echo "✗ Kata runtime not found or not executable: $KATA_RUNTIME"
        return 1
    fi
    {{- end }}

    return $([[ $cri_ok -eq 1 ]] && echo 0 || echo 1)
}

check_network() {
    echo ""
    echo "=== Network Configuration Check ==="
    echo "Network driver: {{ .Values.network.driver }}"
    local network_ok=0

    {{- if eq .Values.network.driver "kuryr" }}
    # Check Kuryr
    if [ "$RUNTIME_TYPE" = "docker" ] && command -v docker >/dev/null 2>&1; then
        echo "Checking for Kuryr network driver..."
        if timeout 10 docker network ls --format '{{`{{.Driver}}`}}' 2>/dev/null | grep -q kuryr; then
            echo "✓ Kuryr network driver is installed"
            network_ok=1
        else
            echo "⚠ Kuryr network driver not found"
            echo "Available drivers:"
            timeout 5 docker network ls --format 'table {{`{{.Name}}`}}\t{{`{{.Driver}}`}}' 2>/dev/null || echo "Could not list network drivers"
        fi
    else
        echo "⚠ Cannot check Kuryr (Docker not available or wrong runtime type)"
    fi
    {{- else if eq .Values.network.driver "cni" }}
    # Check CNI directories and basic setup
    CNI_CONF_DIR="{{ .Values.network.drivers.cni.paths.conf_dir }}"
    CNI_BIN_DIR="{{ .Values.network.drivers.cni.paths.bin_dir }}"

    echo "Checking CNI directories..."
    if [ -d "$CNI_CONF_DIR" ]; then
        echo "✓ CNI config directory exists: $CNI_CONF_DIR"
        local conf_count=$(ls -1 "$CNI_CONF_DIR"/*.conf 2>/dev/null | wc -l)
        echo "- Configuration files: $conf_count"
    else
        echo "⚠ CNI config directory missing: $CNI_CONF_DIR"
        echo "Attempting to create..."
        if mkdir -p "$CNI_CONF_DIR" 2>/dev/null; then
            echo "✓ Created CNI config directory"
        else
            echo "✗ Could not create CNI config directory"
        fi
    fi

    if [ -d "$CNI_BIN_DIR" ]; then
        echo "✓ CNI binary directory exists: $CNI_BIN_DIR"
        local bin_count=$(ls -1 "$CNI_BIN_DIR"/ 2>/dev/null | wc -l)
        echo "- Binary files: $bin_count"

        # Check for essential CNI plugins
        local essential_plugins="bridge loopback"
        local missing_plugins=""
        for plugin in $essential_plugins; do
            if [ -f "$CNI_BIN_DIR/$plugin" ]; then
                echo "✓ Essential plugin found: $plugin"
            else
                echo "⚠ Essential plugin missing: $plugin"
                missing_plugins="$missing_plugins $plugin"
            fi
        done

        if [ -z "$missing_plugins" ]; then
            network_ok=1
        else
            echo "⚠ Missing essential CNI plugins:$missing_plugins"
        fi
    else
        echo "⚠ CNI binary directory missing: $CNI_BIN_DIR"
        echo "Attempting to create..."
        if mkdir -p "$CNI_BIN_DIR" 2>/dev/null; then
            echo "✓ Created CNI binary directory"
        else
            echo "✗ Could not create CNI binary directory"
        fi
    fi

    echo "Note: CNI plugins and configuration will be installed by init containers"
    {{- end }}

    return $([[ $network_ok -eq 1 ]] && echo 0 || echo 1)
}

check_volumes() {
    echo ""
    echo "=== Volume Configuration Check ==="
    echo "Volume drivers: {{ join ", " .Values.volume_driver.driver_list }}"
    local volume_ok=1

    {{- if has "local" .Values.volume_driver.driver_list }}
    # Check local volume directory
    VOLUME_DIR="{{ .Values.volume_driver.volume_dir }}"
    if [ -d "$VOLUME_DIR" ]; then
        echo "✓ Volume directory exists: $VOLUME_DIR"
        echo "- Permissions: $(ls -ld $VOLUME_DIR 2>/dev/null | awk '{print $1}' || echo 'unknown')"
        echo "- Available space: $(df -h $VOLUME_DIR 2>/dev/null | tail -1 | awk '{print $4}' || echo 'unknown')"
    else
        echo "⚠ Volume directory missing: $VOLUME_DIR"
        echo "Attempting to create..."
        if mkdir -p "$VOLUME_DIR" 2>/dev/null; then
            echo "✓ Created volume directory"
        else
            echo "✗ Could not create volume directory"
            volume_ok=0
        fi
    fi
    {{- end }}

    {{- if has "cinder" .Values.volume_driver.driver_list }}
    echo "✓ Cinder volume driver configured (external service)"
    {{- end }}

    return $volume_ok
}

# Main execution with improved error handling
EXIT_CODE=0
CRITICAL_FAILURES=""
WARNINGS=""

# Container runtime check (critical)
case "$RUNTIME_TYPE" in
    docker)
        if ! check_docker; then
            EXIT_CODE=1
            CRITICAL_FAILURES="$CRITICAL_FAILURES docker-runtime"
        fi
        ;;
    cri)
        if ! check_cri; then
            EXIT_CODE=1
            CRITICAL_FAILURES="$CRITICAL_FAILURES cri-runtime"
        fi
        ;;
    *)
        echo "✗ Unknown runtime type: $RUNTIME_TYPE"
        EXIT_CODE=1
        CRITICAL_FAILURES="$CRITICAL_FAILURES unknown-runtime"
        ;;
esac

# Network check (warning level at this stage)
if ! check_network; then
    WARNINGS="$WARNINGS network-config"
    echo "⚠ Network check had issues (non-fatal at this stage)"
fi

# Volume check (warning level at this stage)
if ! check_volumes; then
    WARNINGS="$WARNINGS volume-config"
    echo "⚠ Volume check had issues (non-fatal at this stage)"
fi

# Summary
echo ""
echo "=== Runtime Check Summary ==="
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ All critical checks passed"
    if [ -n "$WARNINGS" ]; then
        echo "⚠ Warnings (non-fatal):$WARNINGS"
        echo "These issues may be resolved during service startup"
    fi
else
    echo "✗ Critical checks failed:$CRITICAL_FAILURES"
    echo "Service may not start properly without resolving these issues"
fi

echo ""
echo "Next steps:"
echo "- Critical failures must be resolved before service startup"
echo "- Warnings will be checked again during service initialization"
echo "- Check logs for detailed error information"

exit $EXIT_CODE