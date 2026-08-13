#!/bin/sh

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

set -eu

STATE={{ .Values.incus.state_path | quote }}
SOCKET={{ .Values.incus.socket | quote }}
RUNTIME={{ .Values.incus.runtime_path | quote }}
LXCFS={{ .Values.incus.lxcfs_path | quote }}

test -S "$SOCKET"
test -d "$RUNTIME"
test -r "$LXCFS/proc/meminfo"
timeout 5 head -n 1 "$LXCFS/proc/meminfo" >/dev/null
INCUS_DIR="$STATE" incus admin waitready --timeout=5 >/dev/null
/tmp/incus-migration-listener.sh check
