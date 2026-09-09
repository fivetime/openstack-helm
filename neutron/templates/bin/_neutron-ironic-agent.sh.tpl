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
COMMAND="${@:-start}"

function start () {
  exec ironic-neutron-agent \
        --config-file /etc/neutron/neutron.conf \
{{- if and ( empty .Values.conf.neutron.DEFAULT.host ) ( .Values.pod.use_fqdn.neutron_agent ) }}
  --config-file /tmp/pod-shared/neutron-agent.ini \
{{- end }}
        --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
        --config-dir /etc/neutron/neutron.conf.d
}

function stop () {
  kill -TERM 1
}

# Liveness: the agent touches heartbeat_file at the end of every
# state-report cycle (see [baremetal_agent] in neutron.conf). A cycle
# that fails is retried by the agent itself; what only a restart fixes
# is a report loop that stopped ticking - dead, or stuck in a call that
# never returns. Neutron shows that as the per-node baremetal agents
# going dead while this process stays Running with 0 restarts.
function liveness () {
  local hb="{{ .Values.conf.neutron.baremetal_agent.heartbeat_file }}"
  local stale_after="{{ .Values.pod.probes.ironic_agent.neutron_ironic_agent.liveness.stale_after }}"
  local now last age
  now=$(date +%s)
  last=$(stat -c %Y "${hb}" 2>/dev/null || echo 0)
  age=$(( now - last ))
  if [ "${age}" -gt "${stale_after}" ]; then
    echo "ironic-neutron-agent: last state-report cycle ${age}s ago (limit ${stale_after}s, file ${hb})" >&2
    exit 1
  fi
}

$COMMAND
