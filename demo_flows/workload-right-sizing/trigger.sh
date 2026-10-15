#!/usr/bin/env bash
# The Workload Right-Sizing demo trigger
#
# Patches risk-assessment-service's resource requests/limits from the actual
# launch baseline (100m/128Mi) to an overprovisioned state (2000m/4Gi) to
# demonstrate how K8s 360 detects the gap between requested and actual usage,
# and how Cloud Cost Intelligence (CCI) recommends right-sizing, reducing
# infrastructure cost while maintaining reliability.
#
# Under real "launch-week" traffic, risk-assessment-service runs at ~5% CPU
# and ~10% memory, making the overprovisioned state invisible to conventional
# APM signals (latency/error rate stay green) — but visible to K8s 360 and
# CCI cost analytics.
#
# Usage:
#   ./trigger.sh overprovision   # Apply the overprovisioned patch
#   ./trigger.sh right-size      # Revert to baseline resources
#   ./trigger.sh status          # Report current resource requests/limits vs baseline

set -euo pipefail

# shellcheck source=../lib/nr-scenario.sh
source "$(dirname "$0")/../lib/nr-scenario.sh"

NAMESPACE="relibank"
SCRIPT_DIR="$(dirname "$0")"
OVERPROVISION_PATCH="${SCRIPT_DIR}/overprovision-patch.yaml"
BASELINE_PATCH="${SCRIPT_DIR}/baseline-patch.yaml"
DEPLOYMENT="risk-assessment-service"

usage() {
  echo "Usage: $0 <overprovision|right-size|status>"
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  overprovision)
    nr_set_context "12" "Workload Right-Sizing - Overprovisioned" "DEPLOYMENT" \
        "risk-assessment-service resource requests/limits bumped to 2vCPU/4Gi (100m/128Mi -> 2000m/4Gi requests) with actual traffic at ~5% CPU / ~10% memory" "risk-assessment-service"
    nr_push_change_tracking

    echo "=== Applying overprovision patch to ${DEPLOYMENT} ==="
    kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --patch-file "$OVERPROVISION_PATCH"

    echo ""
    echo "Resource footprint raised 20x (requests: 100m/128Mi -> 2000m/4Gi; limits:"
    echo "500m/256Mi -> 4000m/8Gi). Actual usage runs at ~5% CPU / ~10% memory under"
    echo "real launch-week traffic, so APM latency/error/throughput should stay green —"
    echo "the workload is reliable despite being over-provisioned."
    echo ""
    echo "K8s 360 + Cost Intelligence to validate:"
    cat <<'NRQL' | sed "s/__CLUSTER__/${AKS_CLUSTER_NAME:?set AKS_CLUSTER_NAME}/g"

-- K8s 360 Application view: risk-assessment-service request vs. actual CPU/memory
-- Shows the gap between allocated requests and observed usage
SELECT avg(cpuRequestedCores), avg(cpuUsedCores),
       avg(memoryRequestedBytes), avg(memoryUsedBytes)
FROM K8sContainerSample
WHERE deploymentName = 'risk-assessment-service'
  AND namespace = 'relibank'
FACET containerName
SINCE 1 hour ago TIMESERIES 5 minutes

-- Cloud Cost Intelligence (CCI): cost-per-transaction and right-size recommendations
-- Once CCI telemetry is enabled, shows projected savings from right-sizing
SELECT sum(cost) FROM KubernetesCost
WHERE clusterName = '__CLUSTER__'
  AND deploymentName = 'risk-assessment-service'
FACET namespace
SINCE 1 day ago

-- APM: confirm latency/error rate stay green despite over-provisioning
FROM Transaction
SELECT percentile(duration, 95) AS 'p95 (s)', percentage(count(*), WHERE error IS true) AS 'Error %'
WHERE appName = 'relibank - Risk Assessment Service'
TIMESERIES 1 minute SINCE 1 hour ago
NRQL
    ;;

  right-size)
    nr_set_context "12" "Workload Right-Sizing - Right-Sized" "DEPLOYMENT" \
        "risk-assessment-service resource requests/limits reverted to baseline (100m/128Mi requests, 500m/256Mi limits) per CCI recommendation" "risk-assessment-service"
    nr_push_change_tracking

    echo "=== Reverting ${DEPLOYMENT} to baseline resources (right-sized) ==="
    kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --patch-file "$BASELINE_PATCH"

    echo "Done. Right-sizing applied. APM latency/error rate should remain green"
    echo "while infrastructure cost drops significantly."
    ;;

  status)
    echo "=== ${DEPLOYMENT} resource requests/limits ==="
    kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
      -o jsonpath='{.spec.template.spec.containers[0].resources}' | python3 -m json.tool 2>/dev/null \
      || kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
           -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'

    echo ""
    echo "Baseline (k8s/base/services/risk-assessment-service-deployment.yaml):"
    echo "  requests: cpu=100m, memory=128Mi | limits: cpu=500m, memory=256Mi"
    echo "Overprovisioned (this trigger's overprovision state):"
    echo "  requests: cpu=2000m, memory=4Gi | limits: cpu=4000m, memory=8Gi"
    ;;

  *)
    usage
    ;;
esac
