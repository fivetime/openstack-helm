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

# Trust the client certificates that read /1.0/metrics: Prometheus's and those
# in incus.metrics.additional_certificates, such as Ceilometer's. A metrics
# certificate reaches nothing but the metrics endpoint, and is restricted to
# incus.metrics.projects, so it sees only the instances of those projects.

set -eu

STATE={{ .Values.incus.state_path | quote }}
PROJECTS={{ join "," .Values.incus.metrics.projects | quote }}
PROJECTS_JSON={{ .Values.incus.metrics.projects | toJson | squote }}

fail() {
    echo "incus-metrics-trust: $*" >&2
    exit 1
}

echo "$PROJECTS" | grep -Eq '^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$' \
    || fail "incus.metrics.projects must name at least one project"

trust() {
    cert=$1
    name=$2

    [ -r "$cert" ] || fail "$cert is not readable"

    # Incus names a certificate by the SHA-256 of its DER encoding.
    fingerprint=$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$cert" \
        | sed '/-----/d' | base64 -d | sha256sum | awk '{ print $1 }')
    [ ${#fingerprint} -eq 64 ] || fail "cannot fingerprint $cert"

    if existing=$(INCUS_DIR="$STATE" incus query "/1.0/certificates/$fingerprint" 2>/dev/null); then
        echo "$existing" | grep -q '"type": "metrics"' \
            || fail "certificate $fingerprint is trusted, but not as a metrics certificate"
        # Restrict a certificate trusted before the restriction existed, and
        # follow a changed project list. PATCH leaves its other fields alone.
        INCUS_DIR="$STATE" incus query -X PATCH "/1.0/certificates/$fingerprint" \
            --data "{\"restricted\": true, \"projects\": $PROJECTS_JSON}" >/dev/null
        echo "incus-metrics-trust: $name ($fingerprint) is trusted, restricted to $PROJECTS"
        return 0
    fi

    INCUS_DIR="$STATE" incus config trust add-certificate "$cert" \
        --type=metrics --name="$name" --restricted --projects="$PROJECTS"
    echo "incus-metrics-trust: trusted $name ($fingerprint) for metrics, restricted to $PROJECTS"
}

INCUS_DIR="$STATE" incus admin waitready --timeout=120 >/dev/null

trust {{ printf "%s/tls.crt" .Values.incus.metrics.mount_path | quote }} \
    {{ .Values.incus.metrics.certificate_name | quote }}
{{- range .Values.incus.metrics.additional_certificates }}
trust {{ printf "%s.d/%s/tls.crt" $.Values.incus.metrics.mount_path .certificate_name | quote }} \
    {{ .certificate_name | quote }}
{{- end }}
