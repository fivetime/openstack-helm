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
KURYR_LOG_DIR=/var/log/kolla/kuryr
if [[ ! -d "${KURYR_LOG_DIR}" ]]; then
    mkdir -p ${KURYR_LOG_DIR}
fi
if [[ $(stat -c %a ${KURYR_LOG_DIR}) != "755" ]]; then
    chmod 755 ${KURYR_LOG_DIR}
fi

# Create Docker plugins directory
KURYR_DOCKER_PLUGINS_DIR={{ .Values.network.kuryr.plugins_dir }}
if [[ ! -d "${KURYR_DOCKER_PLUGINS_DIR}" ]]; then
    mkdir -p ${KURYR_DOCKER_PLUGINS_DIR}
fi

# Create kuryr spec file for Docker
cat > ${KURYR_DOCKER_PLUGINS_DIR}/kuryr.spec << EOF
http://127.0.0.1:23750
EOF

echo "Created kuryr spec file at ${KURYR_DOCKER_PLUGINS_DIR}/kuryr.spec"
cat ${KURYR_DOCKER_PLUGINS_DIR}/kuryr.spec

# Add kolla venv to PATH
export PATH="/var/lib/kolla/venv/bin:$PATH"

# Start kuryr-server (the actual kuryr-libnetwork service)
echo "Starting kuryr-server..."
exec kuryr-server --config-file /etc/kuryr/kuryr.conf