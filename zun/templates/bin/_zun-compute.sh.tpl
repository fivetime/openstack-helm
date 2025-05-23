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

# Test Docker connectivity
echo "Testing Docker connectivity..."
if docker version > /dev/null 2>&1; then
    echo "✓ Docker connectivity verified"
    docker version | head -5
else
    echo "✗ Docker connectivity failed"
    exit 1
fi

# Check for Kuryr network driver
echo "Checking for Kuryr network driver..."
if docker network ls --format "table {{.Driver}}" | grep -q kuryr; then
    echo "✓ Kuryr network driver is available"
    docker network ls | grep kuryr
else
    echo "⚠ Kuryr network driver not found, but continuing..."
    echo "Available network drivers:"
    docker network ls --format "table {{.Name}}\t{{.Driver}}"
fi

exec zun-compute \
    --config-file /etc/zun/zun.conf