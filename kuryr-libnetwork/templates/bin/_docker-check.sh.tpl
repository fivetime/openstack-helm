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

# Debug information
echo "=== Docker Check Debug Info ==="
echo "Current user: $(whoami)"
echo "Current UID: $(id -u)"
echo "Docker socket path: {{ .Values.network.kuryr.docker_socket_path }}"

# Check if Docker socket exists
DOCKER_SOCKET={{ .Values.network.kuryr.docker_socket_path }}
if [[ -S ${DOCKER_SOCKET} ]]; then
    echo "✓ Docker socket exists at ${DOCKER_SOCKET}"
    ls -la ${DOCKER_SOCKET}
else
    echo "✗ Docker socket not found at ${DOCKER_SOCKET}"
    echo "Contents of /var/run/:"
    ls -la /var/run/ | head -10
    exit 1
fi

# Test Docker connectivity with more verbose output
echo "Testing Docker connectivity..."
if docker version; then
    echo "✓ Docker connectivity verified"
else
    echo "✗ Cannot connect to Docker daemon"
    echo "Docker socket permissions:"
    ls -la ${DOCKER_SOCKET}
    echo "Current user groups:"
    groups
    exit 1
fi

# Check if OVS is running (optional)
echo "Testing OVS connectivity..."
if ovs-vsctl show > /dev/null 2>&1; then
    echo "✓ OVS connectivity verified"
else
    echo "⚠ Cannot connect to OVS daemon, but continuing..."
fi

echo "=== All checks completed successfully ==="