#!/bin/bash
# Render the Incus monitor alert rules of the masakari chart and run their
# promtool unit tests. PROMTOOL may name a local promtool; otherwise the
# Prometheus image is run with docker.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "${here}/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

helm template masakari "${top}/masakari" \
  --set manifests.incus_monitor=true \
  --set manifests.incus_notifier=true \
  --set manifests.prometheusrule_incus_monitor=true |
  python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc["kind"] == "PrometheusRule":
        yaml.safe_dump({"groups": doc["spec"]["groups"]}, sys.stdout,
                       sort_keys=False)
        break
else:
    sys.exit("no PrometheusRule rendered")
' > "${work}/rules.yaml"
cp "${here}/test.yaml" "${work}/test.yaml"
# The Prometheus image runs as nobody.
chmod 0755 "${work}"
chmod 0644 "${work}/rules.yaml" "${work}/test.yaml"

if [ -n "${PROMTOOL:-}" ]; then
  cd "${work}"
  "${PROMTOOL}" check rules rules.yaml
  "${PROMTOOL}" test rules test.yaml
else
  image=${PROMETHEUS_IMAGE:-quay.io/prometheus/prometheus:v3.14.0-distroless}
  docker run --rm -v "${work}:/t" -w /t --entrypoint promtool "${image}" \
    check rules rules.yaml
  docker run --rm -v "${work}:/t" -w /t --entrypoint promtool "${image}" \
    test rules test.yaml
fi
