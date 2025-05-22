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

# Ensure CNI directories exist
echo "Setting up CNI directories..."
mkdir -p /etc/cni/net.d
mkdir -p /opt/cni/bin
mkdir -p /var/lib/cni

# Set proper permissions for CNI directories
chmod 755 /etc/cni/net.d
chmod 755 /opt/cni/bin
chmod 755 /var/lib/cni

# Check if CNI plugins are available
if [ -f /opt/cni/bin/loopback ]; then
    echo "CNI plugins found"
    ls -la /opt/cni/bin/
else
    echo "Warning: CNI plugins not found in /opt/cni/bin/"
fi

# Check for existing CNI configurations
if [ -d /etc/cni/net.d ]; then
    config_count=$(ls -1 /etc/cni/net.d/*.conf 2>/dev/null | wc -l)
    echo "Found $config_count CNI configuration files"
fi

# Start the zun-cni-daemon service
exec zun-cni-daemon \
    --config-file /etc/zun/zun.conf \
    --log-file /var/log/zun/zun-cni-daemon.log