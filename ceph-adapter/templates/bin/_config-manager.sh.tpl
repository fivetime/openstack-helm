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
{{- $envAll := . }}

CONFIGMAP_NAME="{{ .Values.output.configmap_name }}"
DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-{{ $envAll.Release.Namespace }}}"

{{- if or (eq .Values.cluster.mode "provider") (eq .Values.cluster.mode "consumer") }}
# =============================================================================
# Provider/Consumer Mode: Discover mon_host from Rook resources
# =============================================================================
CLUSTER_NAMESPACE="{{ .Values.cluster.namespace }}"
MON_ENDPOINTS_CONFIGMAP="{{ .Values.cluster.mon_endpoints_configmap }}"

echo "Mode: {{ .Values.cluster.mode }}"
echo "  Cluster namespace: ${CLUSTER_NAMESPACE}"
echo "  Mon endpoints configmap: ${MON_ENDPOINTS_CONFIGMAP}"

# Get mon endpoints from Rook configmap
# Rook format: a=10.233.0.4:6789,b=10.233.0.5:6789,c=10.233.0.6:6789
MON_ENDPOINTS_RAW=$(kubectl -n "${CLUSTER_NAMESPACE}" get configmap "${MON_ENDPOINTS_CONFIGMAP}" \
  -o jsonpath='{.data.data}')

if [ -z "${MON_ENDPOINTS_RAW}" ]; then
  echo "ERROR: Failed to retrieve mon endpoints from configmap ${MON_ENDPOINTS_CONFIGMAP}"
  echo "       in namespace ${CLUSTER_NAMESPACE}"
  exit 1
fi

# Remove mon identifiers (a=, b=, c=, etc.)
MON_HOST=$(echo "${MON_ENDPOINTS_RAW}" | sed 's/[a-z]=//g')
echo "Discovered mon_host: ${MON_HOST}"

{{- else if eq .Values.cluster.mode "external" }}
# =============================================================================
# External Mode: Use manually provided mon_host
# =============================================================================
{{- if .Values.cluster.mon_host }}
MON_HOST="{{ .Values.cluster.mon_host }}"
echo "Mode: external"
echo "Using provided mon_host: ${MON_HOST}"
{{- else }}
echo "ERROR: External mode requires cluster.mon_host to be configured"
exit 1
{{- end }}

{{- else }}
echo "ERROR: Invalid cluster mode '{{ .Values.cluster.mode }}'"
echo "       Valid modes: provider, consumer, external"
exit 1
{{- end }}

# =============================================================================
# Generate ceph.conf
# =============================================================================
echo ""
echo "Generating ceph.conf"

cat > /tmp/ceph.conf <<EOF
[global]
mon_host = ${MON_HOST}
{{- range $key, $value := .Values.conf.ceph.global }}
{{- if ne $key "mon_host" }}
{{ $key }} = {{ $value }}
{{- end }}
{{- end }}
{{- range $section, $values := .Values.conf.ceph }}
{{- if ne $section "global" }}

[{{ $section }}]
{{- range $key, $value := $values }}
{{ $key }} = {{ $value }}
{{- end }}
{{- end }}
{{- end }}
EOF

echo "Generated ceph.conf:"
cat /tmp/ceph.conf

# =============================================================================
# Create or update the ceph-etc configmap
# =============================================================================
echo ""
echo "Creating/updating configmap in namespace ${DEPLOYMENT_NAMESPACE}"
echo "  ConfigMap name: ${CONFIGMAP_NAME}"

kubectl create configmap "${CONFIGMAP_NAME}" \
  --from-file=ceph.conf=/tmp/ceph.conf \
  --namespace "${DEPLOYMENT_NAMESPACE}" \
  --dry-run=client -o yaml | \
kubectl label --local -f - \
  application=ceph \
  component=ceph-adapter-rook \
  release_group={{ $envAll.Release.Name }} \
  --dry-run=client -o yaml | \
kubectl apply -n "${DEPLOYMENT_NAMESPACE}" -f -

echo "Successfully created/updated configmap ${CONFIGMAP_NAME}"
