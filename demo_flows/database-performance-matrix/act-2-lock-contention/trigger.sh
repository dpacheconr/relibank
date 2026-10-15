#!/usr/bin/env bash
# Act 2 — Silent DB Stall (lock) demo trigger
#
# Usage:
#   ./trigger.sh enable    # Apply the lock-injector Job (holds exclusive lock ~10m)
#   ./trigger.sh disable   # Delete the lock-injector Job (or let the 10m TTL expire)
#   ./trigger.sh status    # Show whether the lock-injector Job is currently running

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"

SCRIPT_DIR="$(dirname "$0")"
MANIFEST="${SCRIPT_DIR}/lock-injector.yaml"
NAMESPACE="relibank"
JOB_NAME="database-performance-matrix-act2-lock-injector"

usage() {
  echo "Usage: $0 <enable|disable|status>"
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  enable)
    nr_set_context "4" "Silent DB Stall" "CHAOS" \
        "Exclusive lock acquired on Ledger table: transaction-service /ledger/* timeouts + dropped Kafka writes" "APM"
    nr_push_change_tracking

    echo "=== Applying lock-injector Job ==="
    MSSQL_CUSTOM_IMAGE="${MSSQL_CUSTOM_IMAGE:-docker.io/${DOCKERHUB_USER:?Set DOCKERHUB_USER or MSSQL_CUSTOM_IMAGE}/mssql-custom:latest}" \
      envsubst < "$MANIFEST" | kubectl apply -f -
    echo "Lock held for ~10 minutes (TTL) or until: ./trigger.sh disable"
    ;;

  disable)
    nr_set_context "4" "Silent DB Stall Resolved" "CHAOS" \
        "Lock released: Ledger table accessible, transaction-service recovers" "APM"
    nr_push_change_tracking

    echo "=== Deleting lock-injector Job ==="
    kubectl delete -f "$MANIFEST" --ignore-not-found

    # Lock-induced ODBC timeouts leave broken connections in transaction-service's pool; it
    # stays at ~100% errors after the lock is gone. Restart it to recover.
    echo "=== Restarting transaction-service to drop poisoned MSSQL connections ==="
    kubectl rollout restart deployment/transaction-service -n "$NAMESPACE"
    kubectl rollout status deployment/transaction-service -n "$NAMESPACE" --timeout=150s || true
    ;;

  status)
    echo "=== Lock-injector Job ==="
    kubectl get job "$JOB_NAME" -n "$NAMESPACE" 2>/dev/null || echo "No lock-injector Job running"
    ;;

  *)
    usage
    ;;
esac
