#!/usr/bin/env bash
# Act 3 — The Competing Query demo trigger
#
# Runs a K8s Job that repeatedly aggregates BankTransactions (2M rows) joined
# to Merchants (50k rows), unindexed, for ~5 minutes — a legitimate analytics
# scan competing for CPU/IO with bill-pay's ordinary transactional writes on
# the same MSSQL instance. Nothing is blocked or locked; both queries stay
# runnable, they just get slower together.
#
# Usage:
#   ./trigger.sh enable    # Launch the analytics scan job (~5 minutes)
#   ./trigger.sh disable   # Cancel the running scan job, push a recovery marker
#   ./trigger.sh status    # Report whether the scan job is currently running

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"
# shellcheck source=../lib-seed.sh
source "$(dirname "$0")/../lib-seed.sh"

NAMESPACE="relibank"
SCRIPT_DIR="$(dirname "$0")"
JOB_MANIFEST="${SCRIPT_DIR}/analytics-scan-job.yaml"
JOB_NAME="database-performance-matrix-act3-analytics-scan"

usage() {
  echo "Usage: $0 <enable|disable|status>"
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  enable)
    nr_set_context "5" "Competing Query" "DEPLOYMENT" \
        "Analytics scan launched: unindexed aggregation over BankTransactions joined to Merchants, competing for CPU/IO with bill-pay's transactional writes on the same MSSQL instance" "transaction-service"
    nr_push_change_tracking

    ensure_banking_seed

    echo "=== Launching analytics scan job (~5 minutes) ==="
    MSSQL_CUSTOM_IMAGE="${MSSQL_CUSTOM_IMAGE:-docker.io/${DOCKERHUB_USER:?Set DOCKERHUB_USER or MSSQL_CUSTOM_IMAGE}/mssql-custom:latest}" \
      envsubst < "$JOB_MANIFEST" | kubectl apply -f -

    echo ""
    echo "Scan running. Allow ~30-60s for:"
    echo "  - DB 360 resource waits (SOS_SCHEDULER_YIELD, PAGEIOLATCH_*, CXPACKET) to climb"
    echo "  - bill-pay-service p95 latency to rise steadily, with error rate staying flat"
    echo ""
    echo "NRQL to watch (DB 360 resource-wait signature vs APM):"
    cat <<'NRQL'
-- MSSQL resource waits (CPU/IO scheduling, NOT lock waits — contrast with Act 2)
FROM Metric
SELECT average(sqlserver.os.wait.duration)
WHERE metricName = 'sqlserver.os.wait.duration'
  AND wait.type IN ('SOS_SCHEDULER_YIELD', 'CXPACKET', 'PAGEIOLATCH_SH', 'PAGEIOLATCH_EX', 'PAGEIOLATCH_UP', 'IO_COMPLETION')
FACET wait.type TIMESERIES 1 minute SINCE 30 minutes ago

-- Bill-pay p95 latency (should climb) vs error rate (should stay flat)
FROM Transaction
SELECT percentile(duration, 95) AS 'p95 (s)', percentage(count(*), WHERE error IS true) AS 'Error %'
WHERE appName = 'relibank - Bill Pay Service'
TIMESERIES 1 minute SINCE 30 minutes ago
NRQL
    echo ""
    echo "The job self-terminates after ~5 minutes. To cancel early: ./trigger.sh disable"
    ;;

  disable)
    nr_set_context "5" "Competing Query Resolved" "DEPLOYMENT" \
        "Analytics scan cancelled: BankTransactions/Merchants aggregation stopped, MSSQL CPU/IO returning to baseline" "transaction-service"
    nr_push_change_tracking

    echo "=== Cancelling analytics scan job ==="
    kubectl delete -f "$JOB_MANIFEST" --ignore-not-found

    echo "Done. Allow ~30-60s for MSSQL resource waits and bill-pay p95 latency to normalise."
    echo "Unlike Act 2/Act 1, this scan never held a lock or an open transaction — no"
    echo "transaction-service restart should be needed for recovery."
    ;;

  status)
    echo "=== Analytics Scan Job ==="
    kubectl get job "$JOB_NAME" -n "$NAMESPACE" 2>/dev/null || echo "No scan job running"

    echo ""
    echo "=== Scan Pod Logs (tail) ==="
    kubectl logs -l scenario=database-performance-matrix-act3 -n "$NAMESPACE" --tail=5 2>/dev/null || echo "No logs yet"

    echo ""
    echo "=== MSSQL Pod ==="
    kubectl get pods -n "$NAMESPACE" -l app=mssql \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
    ;;

  *)
    usage
    ;;
esac
