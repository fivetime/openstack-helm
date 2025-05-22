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

# Test Docker socket accessibility using curl or nc
echo "Testing Docker socket accessibility..."
if command -v curl >/dev/null 2>&1; then
    # Use curl to test Docker API
    if curl -s --unix-socket ${DOCKER_SOCKET} http://localhost/version >/dev/null 2>&1; then
        echo "✓ Docker socket is accessible via HTTP API"
    else
        echo "⚠ Docker socket exists but HTTP API test failed"
    fi
elif command -v nc >/dev/null 2>&1; then
    # Use netcat to test socket
    if echo -e "GET /version HTTP/1.0\r\n\r\n" | nc -U ${DOCKER_SOCKET} >/dev/null 2>&1; then
        echo "✓ Docker socket is accessible via netcat"
    else
        echo "⚠ Docker socket exists but netcat test failed"
    fi
else
    # Just check if we can read the socket
    if [[ -r ${DOCKER_SOCKET} && -w ${DOCKER_SOCKET} ]]; then
        echo "✓ Docker socket has read/write permissions"
    else
        echo "✗ Docker socket permission denied"
        echo "Socket permissions:"
        ls -la ${DOCKER_SOCKET}
        exit 1
    fi
fi

# Check if OVS is running (optional)
echo "Testing OVS connectivity..."
if command -v ovs-vsctl >/dev/null 2>&1; then
    if ovs-vsctl show > /dev/null 2>&1; then
        echo "✓ OVS connectivity verified"
    else
        echo "⚠ Cannot connect to OVS daemon, but continuing..."
    fi
else
    echo "⚠ ovs-vsctl command not found, skipping OVS check"
fi

echo "=== All checks completed successfully ==="