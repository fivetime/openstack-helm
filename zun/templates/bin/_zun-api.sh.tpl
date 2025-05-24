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

echo "=== Starting Zun API ==="

# Check configuration
if [ -f /etc/zun/zun.conf ]; then
    echo "Configuration file found"
    # 显示关键配置（隐藏密码）
    grep -E "^(host_ip|port|workers)" /etc/zun/zun.conf | grep -v password || true
else
    echo "Error: Configuration file not found"
    exit 1
fi

# Check if running under Apache mod_wsgi or standalone
if [ "${ENABLE_HTTPD_MOD_WSGI_SERVICES}" == "true" ]; then
    echo "Running under Apache mod_wsgi"
    # Apache will be started by the base image
    exec httpd -DFOREGROUND
else
    echo "Running standalone WSGI server"
    exec zun-api \
        --config-file /etc/zun/zun.conf
fi