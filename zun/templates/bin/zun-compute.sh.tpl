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

# Create log directory
mkdir -p /var/log/zun

# Set ownership and permissions
chown zun:zun /var/log/zun
chmod 755 /var/log/zun

# Setup Docker group access
if [ -S /var/run/docker.sock ]; then
    echo "Setting up Docker socket access..."
    gid=$(stat -c "%g" /var/run/docker.sock)

    # Create docker group with the same GID as docker socket
    if ! getent group docker > /dev/null 2>&1; then
        groupadd --force --gid $gid docker
    fi

    # Add zun user to docker group
    usermod -aG docker zun

    # Verify docker access
    if groups zun | grep -q docker; then
        echo "Zun user successfully added to docker group"
    else
        echo "Warning: Failed to add zun user to docker group"
    fi
fi

# Test Docker connectivity
echo "Testing Docker connectivity..."
if docker version > /dev/null 2>&1; then
    echo "Docker connectivity test passed"
else
    echo "Warning: Docker connectivity test failed"
fi

# Start the zun-compute service
exec zun-compute \
    --config-file /etc/zun/zun.conf \
    --log-file /var/log/zun/zun-compute.log