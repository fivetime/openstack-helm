#!/bin/bash
# promtool tests for the Incus monitor alert rules of the masakari chart.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec "${here}/../run-chart-rule-tests.sh" "${here}/../../../masakari" \
  "${here}/test.yaml" \
  --set manifests.incus_monitor=true \
  --set manifests.incus_notifier=true \
  --set manifests.prometheusrule_incus_monitor=true
