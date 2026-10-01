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

# Trust the client certificate Prometheus reads /1.0/metrics with. A metrics
# certificate reaches nothing but the metrics endpoint.

set -eu

STATE={{ .Values.incus.state_path | quote }}
CERT={{ printf "%s/tls.crt" .Values.incus.metrics.mount_path | quote }}
NAME={{ .Values.incus.metrics.certificate_name | quote }}

fail() {
    echo "incus-metrics-trust: $*" >&2
    exit 1
}

[ -r "$CERT" ] || fail "$CERT is not readable"

# Incus names a certificate by the SHA-256 of its DER encoding.
fingerprint=$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$CERT" \
    | sed '/-----/d' | base64 -d | sha256sum | awk '{ print $1 }')
[ ${#fingerprint} -eq 64 ] || fail "cannot fingerprint $CERT"

INCUS_DIR="$STATE" incus admin waitready --timeout=120 >/dev/null

if existing=$(INCUS_DIR="$STATE" incus query "/1.0/certificates/$fingerprint" 2>/dev/null); then
    echo "$existing" | grep -q '"type": "metrics"' \
        || fail "certificate $fingerprint is trusted, but not as a metrics certificate"
    echo "incus-metrics-trust: $NAME ($fingerprint) is already trusted"
    exit 0
fi

INCUS_DIR="$STATE" incus config trust add-certificate "$CERT" \
    --type=metrics --name="$NAME"
echo "incus-metrics-trust: trusted $NAME ($fingerprint) for metrics"
