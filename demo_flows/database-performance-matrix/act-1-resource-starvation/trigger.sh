#!/usr/bin/env bash
# Act 1 — Resource Starvation demo trigger
#
# Applies chaos-experiment.yaml: a StressChaos (CPU + memory) plus a
# NetworkChaos (latency) targeting the mssql pod directly — MSSQL resource
# starvation, not a Kafka fault.
#
# Usage:
#   ./trigger.sh start    # Apply MSSQL CPU/memory stress + network delay
#   ./trigger.sh stop     # Remove chaos experiment (restore normal traffic)
#   ./trigger.sh status   # Show active chaos experiments and pod state

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"

NAMESPACE="relibank"
SCRIPT_DIR="$(dirname "$0")"
EXPERIMENT="${SCRIPT_DIR}/chaos-experiment.yaml"

usage() {
  echo "Usage: $0 <start|stop|status>"
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  start)
    nr_set_context "4" "P1 Outage" "CHAOS" \
        "MSSQL resource starvation: CPU/memory StressChaos + network delay injected on the mssql pod — query latency and connection wait climb, bill-pay 500s follow" "ALL"
    nr_push_change_tracking

    echo "=== Injecting MSSQL CPU/memory stress + network delay ==="
    kubectl apply -f "$EXPERIMENT"

    echo ""
    echo "Chaos active. Allow ~90 seconds for:"
    echo "  - MSSQL pod CPU throttling (K8s 360) to appear first"
    echo "  - MSSQL query latency + wait stats (DB 360) to climb"
    echo "  - Bill-pay 500s (APM) to surface last"
    echo ""
    echo "NRQL to watch (K8s 360 + DB 360):"
    cat <<'NRQL'
-- MSSQL pod CPU throttling (K8s 360)
FROM K8sContainerSample
SELECT average(containerCpuCfsThrottledSecondsDelta), average(cpuUsedCores)
WHERE containerName = 'mssql' AND namespaceName = 'relibank'
SINCE 30 minutes ago TIMESERIES 1 minute

-- Bill-pay error rate
FROM Transaction
SELECT percentage(count(*), WHERE error IS true) AS 'Error %'
WHERE appName LIKE '%Bill Pay%' TIMESERIES 1 minute SINCE 30 minutes ago
NRQL
    echo ""
    echo "To stop: ./trigger.sh stop"
    ;;

  stop)
    nr_set_context "4" "P1 Outage Resolved" "CHAOS" \
        "MSSQL chaos removed: CPU/memory stress and network delay stopped, traffic normalising" "ALL"
    nr_push_change_tracking

    echo "=== Removing MSSQL chaos (StressChaos + NetworkChaos) ==="
    kubectl delete -f "$EXPERIMENT" --ignore-not-found

    # The ODBC pool in transaction-service is left with broken connections ("connection is
    # broken and recovery is not possible") and never recovers on its own, which keeps
    # transaction-service and bill-pay at ~100% errors after the chaos is gone. Restart it.
    echo "=== Restarting transaction-service to drop poisoned MSSQL connections ==="
    kubectl rollout restart deployment/transaction-service -n "$NAMESPACE"
    kubectl rollout status deployment/transaction-service -n "$NAMESPACE" --timeout=150s || true

    echo "Done. Allow ~60 seconds for bill-pay to normalise."
    ;;

  status)
    echo "=== Active StressChaos / NetworkChaos ==="
    kubectl get stresschaos,networkchaos -n "$NAMESPACE" 2>/dev/null || echo "No chaos resources found"

    echo ""
    echo "=== MSSQL Pod ==="
    kubectl get pods -n "$NAMESPACE" -l app=mssql \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName

    echo ""
    echo "=== Bill-Pay Pods ==="
    kubectl get pods -n "$NAMESPACE" -l app=bill-pay-service \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount
    ;;

  *)
    usage
    ;;
esac
