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

# Run the neutron-ovnic orchestrator agent (foreground / PID 1 for k8s). It is
# a pure TCP client of the local OVN NB/SB and the global IC NB/SB; all
# connection targets are stable Service DNS names (the agent re-resolves them on
# every (re)connect via the ovsdb_dns patch, so a backend ClusterIP change does
# not strand it).

set -ex

CONF="/etc/neutron-ovnic/neutron-ovnic.conf"

# Seed the desired-state file on first start so the reconcile loop loads
# cleanly (empty list = manage nothing until interconnections are declared).
IC_FILE="$(awk -F'=' '/^[[:space:]]*interconnections_file[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2}' "${CONF}" | tail -1)"
if [ -n "${IC_FILE}" ]; then
  mkdir -p "$(dirname "${IC_FILE}")"
  [ -f "${IC_FILE}" ] || echo '[]' > "${IC_FILE}"
fi

exec neutron-ovnic-agent --config-file "${CONF}"
