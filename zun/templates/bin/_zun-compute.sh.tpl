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

# Find Docker socket
DOCKER_SOCK=""
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK="/var/run/docker.sock"
elif [ -S /run/docker.sock ]; then
    DOCKER_SOCK="/run/docker.sock"
else
    echo "Error: Docker socket not found in /var/run/docker.sock or /run/docker.sock"
    echo "Available sockets in /var/run:"
    find /var/run -name "*.sock" -type s 2>/dev/null || echo "No sockets found"
    echo "Available sockets in /run:"
    find /run -name "*.sock" -type s 2>/dev/null || echo "No sockets found"
    exit 1
fi

echo "Found Docker socket at: $DOCKER_SOCK"
export DOCKER_HOST="unix://$DOCKER_SOCK"

# Enhanced Docker connectivity testing
echo "=== Docker Connectivity Debug ==="
echo "Current user: $(whoami) ($(id))"
echo "Docker socket: $(ls -la $DOCKER_SOCK)"
echo "Docker socket type: $(file $DOCKER_SOCK)"

# Test Docker connectivity
echo "Testing Docker connectivity with DOCKER_HOST=$DOCKER_HOST..."
if timeout 10 docker version 2>&1; then
    echo "✓ Docker connectivity verified"
    docker version | head -5
else
    echo "✗ Docker connectivity failed"
    echo "Debug information:"
    echo "- Socket permissions: $(ls -la $DOCKER_SOCK)"
    echo "- Current user: $(id)"
    echo "- Available groups: $(groups)"

    # Try to fix permissions as last resort
    chmod 666 $DOCKER_SOCK 2>/dev/null && echo "Fixed socket permissions" || echo "Could not fix permissions"

    # Try again
    if timeout 10 docker version >/dev/null 2>&1; then
        echo "✓ Docker connectivity restored after permission fix"
    else
        echo "✗ Docker still not accessible, continuing anyway..."
    fi
fi

# Check for Kuryr network driver
echo "Checking for network drivers..."
if timeout 10 docker network ls 2>/dev/null; then
    if docker network ls --format "table {{.Driver}}" 2>/dev/null | grep -q kuryr; then
        echo "✓ Kuryr network driver is available"
        docker network ls | grep kuryr
    else
        echo "⚠ Kuryr network driver not found"
        echo "Available network drivers:"
        docker network ls --format "table {{.Name}}\t{{.Driver}}" 2>/dev/null || echo "Could not list drivers"
    fi
else
    echo "⚠ Could not list Docker networks"
fi

echo "=== Starting zun-compute ==="
exec zun-compute \
    --config-file /etc/zun/zun.conf