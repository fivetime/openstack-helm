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

SECRET_NAME="{{ .Values.output.secret_name }}"
DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-{{ $envAll.Release.Namespace }}}"

{{- if eq .Values.deployment.mode "provider" }}
# =============================================================================
# Provider Mode: Local Rook-Ceph cluster with admin access
# =============================================================================
CLUSTER_NAMESPACE="{{ .Values.provider.cluster_namespace }}"
ADMIN_SECRET="{{ .Values.provider.admin_secret }}"
CEPH_USER="admin"

echo "Mode: provider"
echo "  Cluster namespace: ${CLUSTER_NAMESPACE}"
echo "  Admin secret: ${ADMIN_SECRET}"

# Get admin keyring from Rook mon secret
# The rook-ceph-mon secret contains 'ceph-secret' key with admin keyring
CEPH_CLIENT_KEY=$(kubectl -n "${CLUSTER_NAMESPACE}" get secret "${ADMIN_SECRET}" \
  -o jsonpath='{.data.ceph-secret}' | base64 -d)

if [ -z "${CEPH_CLIENT_KEY}" ]; then
  echo "ERROR: Failed to retrieve admin keyring from secret ${ADMIN_SECRET}"
  echo "       in namespace ${CLUSTER_NAMESPACE}"
  exit 1
fi

echo "Successfully retrieved admin keyring from Rook"

{{- else if eq .Values.deployment.mode "consumer" }}
# =============================================================================
# Consumer Mode: Rook-Ceph external cluster with CSI access
# =============================================================================
CLUSTER_NAMESPACE="{{ .Values.consumer.cluster_namespace }}"
CSI_SECRET="{{ .Values.consumer.csi_rbd_provisioner_secret }}"
CEPH_USER="csi-rbd-provisioner"

echo "Mode: consumer"
echo "  Cluster namespace: ${CLUSTER_NAMESPACE}"
echo "  CSI secret: ${CSI_SECRET}"

# Get keyring from Rook CSI RBD provisioner secret
CEPH_CLIENT_KEY=$(kubectl -n "${CLUSTER_NAMESPACE}" get secret "${CSI_SECRET}" \
  -o jsonpath='{.data.userKey}' | base64 -d)

if [ -z "${CEPH_CLIENT_KEY}" ]; then
  echo "ERROR: Failed to retrieve CSI keyring from secret ${CSI_SECRET}"
  echo "       in namespace ${CLUSTER_NAMESPACE}"
  exit 1
fi

echo "Successfully retrieved CSI provisioner keyring from Rook"

{{- else if eq .Values.deployment.mode "external" }}
# =============================================================================
# External Mode: Non-Rook Ceph cluster with manual configuration
# =============================================================================
CEPH_USER="{{ .Values.external.ceph_user }}"

echo "Mode: external"

{{- if .Values.external.keyring.secret_ref.name }}
# Get keyring from existing secret reference
EXTERNAL_SECRET_NAME="{{ .Values.external.keyring.secret_ref.name }}"
EXTERNAL_SECRET_KEY="{{ .Values.external.keyring.secret_ref.key | default "key" }}"
{{- if .Values.external.keyring.secret_ref.namespace }}
EXTERNAL_SECRET_NAMESPACE="{{ .Values.external.keyring.secret_ref.namespace }}"
{{- else }}
EXTERNAL_SECRET_NAMESPACE="${DEPLOYMENT_NAMESPACE}"
{{- end }}

echo "  Secret name: ${EXTERNAL_SECRET_NAME}"
echo "  Secret namespace: ${EXTERNAL_SECRET_NAMESPACE}"

CEPH_CLIENT_KEY=$(kubectl -n "${EXTERNAL_SECRET_NAMESPACE}" get secret "${EXTERNAL_SECRET_NAME}" \
  -o jsonpath="{.data.${EXTERNAL_SECRET_KEY}}" | base64 -d)

if [ -z "${CEPH_CLIENT_KEY}" ]; then
  echo "ERROR: Failed to retrieve keyring from secret ${EXTERNAL_SECRET_NAME}"
  echo "       in namespace ${EXTERNAL_SECRET_NAMESPACE}"
  exit 1
fi

echo "Successfully retrieved keyring from external secret"

{{- else if .Values.external.keyring.key }}
# Use directly provided keyring
CEPH_CLIENT_KEY="{{ .Values.external.keyring.key }}"
echo "Using directly provided keyring"

{{- else }}
echo "ERROR: External mode requires either keyring.key or keyring.secret_ref.name"
exit 1
{{- end }}

{{- else }}
echo "ERROR: Invalid deployment mode '{{ .Values.deployment.mode }}'"
echo "       Valid modes: provider, consumer, external"
exit 1
{{- end }}

# =============================================================================
# Create or update the client keyring secret
# =============================================================================
echo ""
echo "Creating/updating secret in namespace ${DEPLOYMENT_NAMESPACE}"
echo "  Secret name: ${SECRET_NAME}"
echo "  Ceph user: ${CEPH_USER}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${DEPLOYMENT_NAMESPACE}
  labels:
    application: ceph
    component: ceph-adapter-rook
    release_group: {{ $envAll.Release.Name }}
type: Opaque
stringData:
  key: "${CEPH_CLIENT_KEY}"
EOF

echo "Successfully created/updated secret ${SECRET_NAME}"
