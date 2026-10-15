#!/usr/bin/env bash
# Act 4 — The Silent Regression demo trigger
#
# Drops IX_BankTxn_Account on BankTransactions, then loops an account-lookup
# query for ~5 minutes. Baseline: index seek. After the drop: clustered index
# scan across 2M rows — a 10-50x plan regression with no lock waits and no
# CPU/IO contention with other queries, contrasting Scenarios 4 (lock) and
# 5 (resource contention).
#
# Usage:
#   ./trigger.sh enable    # Drop the index, launch the driver job (~5 minutes)
#   ./trigger.sh disable   # Cancel the driver job, recreate the index, push a recovery marker
#   ./trigger.sh status    # Report whether the index exists and whether the driver job is running

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"
# shellcheck source=../lib-seed.sh
source "$(dirname "$0")/../lib-seed.sh"

NAMESPACE="relibank"
SCRIPT_DIR="$(dirname "$0")"
DROP_MANIFEST="${SCRIPT_DIR}/index-drop-job.yaml"
RESTORE_MANIFEST="${SCRIPT_DIR}/index-restore-job.yaml"
DRIVER_MANIFEST="${SCRIPT_DIR}/regression-driver-job.yaml"
DRIVER_JOB_NAME="database-performance-matrix-act4-regression-driver"

usage() {
  echo "Usage: $0 <enable|disable|status>"
  exit 1
}

wait_for_job() {
  local job_name="$1"
  kubectl wait --for=condition=complete --timeout=60s -n "$NAMESPACE" "job/${job_name}" 2>/dev/null || true
}

[[ $# -lt 1 ]] && usage

case "$1" in
  enable)
    nr_set_context "6" "Silent Regression" "DEPLOYMENT" \
        "Index dropped: IX_BankTxn_Account removed from BankTransactions, flipping the account-lookup query's plan from an index seek to a clustered index scan" "transaction-service"
    nr_push_change_tracking

    ensure_banking_seed

    echo "=== Dropping IX_BankTxn_Account ==="
    MSSQL_CUSTOM_IMAGE="${MSSQL_CUSTOM_IMAGE:-docker.io/${DOCKERHUB_USER:?Set DOCKERHUB_USER or MSSQL_CUSTOM_IMAGE}/mssql-custom:latest}" \
      envsubst '${MSSQL_CUSTOM_IMAGE}' < "$DROP_MANIFEST" | kubectl apply -f -
    wait_for_job "database-performance-matrix-act4-index-drop"

    echo ""
    echo "=== Launching account-lookup driver job (~5 minutes) ==="
    MSSQL_CUSTOM_IMAGE="${MSSQL_CUSTOM_IMAGE:-docker.io/${DOCKERHUB_USER:?Set DOCKERHUB_USER or MSSQL_CUSTOM_IMAGE}/mssql-custom:latest}" \
      envsubst '${MSSQL_CUSTOM_IMAGE}' < "$DRIVER_MANIFEST" | kubectl apply -f -

    echo ""
    echo "Driver running. Allow ~30-60s for:"
    echo "  - DB 360 plan hash to change and logical reads to jump by orders of magnitude"
    echo "  - No LCK_% wait growth (rules out Act 2). Note: CXPACKET/PAGEIOLATCH"
    echo "    growth is expected here too (same signature as Act 3's scan) —"
    echo "    it does NOT rule out Act 3; only the lock-wait check does."
    echo ""
    echo "The driver job self-terminates after ~5 minutes. To restore early: ./trigger.sh disable"
    ;;

  disable)
    echo "=== Cancelling driver job (if still running) ==="
    kubectl delete -f "$DRIVER_MANIFEST" --ignore-not-found

    echo ""
    echo "=== Recreating IX_BankTxn_Account ==="
    MSSQL_CUSTOM_IMAGE="${MSSQL_CUSTOM_IMAGE:-docker.io/${DOCKERHUB_USER:?Set DOCKERHUB_USER or MSSQL_CUSTOM_IMAGE}/mssql-custom:latest}" \
      envsubst '${MSSQL_CUSTOM_IMAGE}' < "$RESTORE_MANIFEST" | kubectl apply -f -
    wait_for_job "database-performance-matrix-act4-index-restore"

    nr_set_context "6" "Silent Regression Resolved" "DEPLOYMENT" \
        "Index recreated: IX_BankTxn_Account restored on BankTransactions, plan reverting to an index seek" "transaction-service"
    nr_push_change_tracking

    echo "Done. Allow ~30-60s for the plan hash to revert and logical reads to drop."
    echo "Schema-only change, no data touched, no locks held — a transaction-service"
    echo "restart should not be needed for recovery (unlike Act 1's MSSQL chaos)."
    ;;

  status)
    echo "=== IX_BankTxn_Account ==="
    MSSQL_CUSTOM_IMAGE="${MSSQL_CUSTOM_IMAGE:-docker.io/${DOCKERHUB_USER:?Set DOCKERHUB_USER or MSSQL_CUSTOM_IMAGE}/mssql-custom:latest}" \
      envsubst '${MSSQL_CUSTOM_IMAGE}' <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: database-performance-matrix-act4-status-check
  namespace: relibank
  labels:
    app: relibank
    scenario: database-performance-matrix-act4
spec:
  restartPolicy: Never
  containers:
  - name: status-check
    image: ${MSSQL_CUSTOM_IMAGE}
    imagePullPolicy: IfNotPresent
    command:
      - /opt/mssql-tools18/bin/sqlcmd
      - -S
      - mssql-0
      - -U
      - $(MSSQL_SA_USER)
      - -P
      - $(MSSQL_SA_PASSWORD)
      - -C
      - -d
      - RelibankDB
      - -Q
      - "SELECT name AS IndexName FROM sys.indexes WHERE object_id = OBJECT_ID('BankTransactions') AND name = 'IX_BankTxn_Account';"
    env:
    - name: MSSQL_SA_PASSWORD
      valueFrom:
        secretKeyRef:
          name: database-credentials
          key: MSSQL_SA_PASSWORD
    - name: MSSQL_SA_USER
      valueFrom:
        secretKeyRef:
          name: database-credentials
          key: MSSQL_SA_USER
EOF
    kubectl wait --for=condition=Ready --timeout=30s -n "$NAMESPACE" pod/database-performance-matrix-act4-status-check 2>/dev/null || true
    sleep 3
    kubectl logs database-performance-matrix-act4-status-check -n "$NAMESPACE" 2>/dev/null || echo "(status check pod not ready yet)"
    kubectl delete pod database-performance-matrix-act4-status-check -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

    echo ""
    echo "=== Regression Driver Job ==="
    kubectl get job "$DRIVER_JOB_NAME" -n "$NAMESPACE" 2>/dev/null || echo "No driver job running"

    echo ""
    echo "=== MSSQL Pod ==="
    kubectl get pods -n "$NAMESPACE" -l app=mssql \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
    ;;

  *)
    usage
    ;;
esac
