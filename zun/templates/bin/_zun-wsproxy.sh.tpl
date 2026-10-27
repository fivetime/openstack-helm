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

{{- if .Values.pod.wsproxy_max_processes }}

# A process per connection, forked before the token is checked: cap the
# processes (and threads) of this UID so a flood exhausts only the proxy.
ulimit -u {{ .Values.pod.wsproxy_max_processes }}
{{- end }}

{{- if and .Values.manifests.daemonset_wsproxy .Values.network.wsproxy.edge.enabled }}

# On a compute node behind the Envoy sidecar: listen on loopback only.
WSPROXY_NODE_CONF=""
if [ -f /etc/zun/wsproxy-node.conf ]; then
    WSPROXY_NODE_CONF="--config-file /etc/zun/wsproxy-node.conf"
fi
{{- end }}

exec zun-wsproxy \
    --config-file /etc/zun/zun.conf{{ if and .Values.manifests.daemonset_wsproxy .Values.network.wsproxy.edge.enabled }} \
    ${WSPROXY_NODE_CONF}{{ end }}