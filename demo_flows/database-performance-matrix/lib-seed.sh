#!/usr/bin/env bash
# Shared helper for Database Performance Matrix Acts 3 and 4.
# Source it, then call ensure_banking_seed before the Act applies its own Job.
#
# Runs seed-data-job.yaml (idempotent: only inserts when Merchants / BankTransactions are empty),
# waits for it, and prints its log. A first run inserts ~2M rows (~1 minute); later runs are two COUNTs.

ensure_banking_seed() {
  local namespace="${NAMESPACE:-relibank}"
  local manifest
  manifest="$(dirname "${BASH_SOURCE[0]}")/seed-data-job.yaml"
  local job="database-performance-matrix-seed"

  echo "=== Ensuring Merchants / BankTransactions are seeded ==="
  kubectl delete job "$job" -n "$namespace" --ignore-not-found >/dev/null 2>&1 || true
  MSSQL_CUSTOM_IMAGE="${MSSQL_CUSTOM_IMAGE:-docker.io/${DOCKERHUB_USER:?Set DOCKERHUB_USER or MSSQL_CUSTOM_IMAGE}/mssql-custom:latest}" \
    envsubst '${MSSQL_CUSTOM_IMAGE}' < "$manifest" | kubectl apply -f -

  if ! kubectl wait --for=condition=complete "job/$job" -n "$namespace" --timeout=200s; then
    echo "ERROR: seed Job did not complete; log follows" >&2
    kubectl logs "job/$job" -n "$namespace" --tail=30 >&2 || true
    return 1
  fi
  kubectl logs "job/$job" -n "$namespace" --tail=10 || true
}
