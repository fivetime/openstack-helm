#!/bin/bash
# Render the PrometheusRule objects of a chart and run promtool unit tests
# against them.
#
#   run-chart-rule-tests.sh <chart dir> <test file> [helm template args...]
#
# PROMTOOL may name a local promtool; otherwise the Prometheus image is run
# with docker.
set -euo pipefail

chart=$1
tests=$2
shift 2

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

helm template rules "${chart}" "$@" |
  python3 -c '
import sys, yaml
groups = []
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc["kind"] == "PrometheusRule":
        groups += doc["spec"]["groups"]
if not groups:
    sys.exit("no PrometheusRule rendered")
yaml.safe_dump({"groups": groups}, sys.stdout, sort_keys=False)
' > "${work}/rules.yaml"
cp "${tests}" "${work}/test.yaml"
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
