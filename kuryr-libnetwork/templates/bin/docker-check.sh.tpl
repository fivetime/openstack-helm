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

# Check if Docker socket is accessible
DOCKER_SOCKET={{ .Values.network.kuryr.docker_socket_path }}
if [[ ! -S ${DOCKER_SOCKET} ]]; then
    echo "ERROR: Docker socket not found at ${DOCKER_SOCKET}"
    exit 1
fi

# Test Docker connectivity
if ! docker version > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to Docker daemon"
    exit 1
fi

echo "Docker connectivity verified"

# Check if OVS is running
if ! ovs-vsctl show > /dev/null 2>&1; then
    echo "WARNING: Cannot connect to OVS daemon, but continuing..."
else
    echo "OVS connectivity verified"
fi