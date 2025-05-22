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

BIND_HOST="{{ .Values.network.kuryr.bind_host }}"
BIND_PORT="{{ .Values.network.kuryr.bind_port }}"
UWSGI_PROCESSES="{{ .Values.network.kuryr.uwsgi_processes }}"
UWSGI_THREADS="{{ .Values.network.kuryr.uwsgi_threads }}"

echo "=== Kuryr uwsgi Configuration ==="
echo "Bind Host: ${BIND_HOST}"
echo "Bind Port: ${BIND_PORT}"
echo "Processes: ${UWSGI_PROCESSES}"
echo "Threads: ${UWSGI_THREADS}"

# Create kuryr spec file for Docker
cat > ${KURYR_DOCKER_PLUGINS_DIR}/kuryr.spec << EOF
http://127.0.0.1:${BIND_PORT}
EOF

echo "Created kuryr spec file at ${KURYR_DOCKER_PLUGINS_DIR}/kuryr.spec"

# Add kolla venv to PATH
export PATH="/var/lib/kolla/venv/bin:$PATH"

if ! command -v uwsgi >/dev/null 2>&1; then
    echo "ERROR: uwsgi is required but not found in PATH"
    echo "Please ensure uwsgi is installed in the container image"
    exit 1
fi

echo "Starting kuryr via uwsgi..."
exec uwsgi \
    --plugins python \
    --http-socket ${BIND_HOST}:${BIND_PORT} \
    --wsgi kuryr_libnetwork.server:app \
    --pyargv "--config-file /etc/kuryr/kuryr.conf" \
    --master \
    --need-app \
    --processes ${UWSGI_PROCESSES} \
    --threads ${UWSGI_THREADS} \
    --die-on-term