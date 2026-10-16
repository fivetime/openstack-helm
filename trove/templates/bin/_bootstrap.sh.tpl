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
export HOME=/tmp

{{- if .Values.bootstrap.structured.datastores }}

cat > /tmp/datastores.json <<'END_OF_DATASTORES'
{{ toJson .Values.bootstrap.structured.datastores }}
END_OF_DATASTORES

python3 - /tmp/datastores.json <<'END_OF_SCRIPT'
{{ tuple "bin/_bootstrap-datastores.py.tpl" . | include "helm-toolkit.utils.template" }}
END_OF_SCRIPT
{{- end }}

{{ .Values.bootstrap.script | default "echo 'No bootstrap script'" }}
