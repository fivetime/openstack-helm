#!/bin/bash
# promtool tests for the instance resource alert rules of the incus chart.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec "${here}/../run-chart-rule-tests.sh" "${here}/../../../incus" \
  "${here}/test.yaml" \
  --set incus.metrics.enabled=true \
  --set incus.migration.enabled=true \
  --set manifests.podmonitor_incus=true \
  --set manifests.prometheusrule_incus=true
