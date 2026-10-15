#!/usr/bin/env bash
# Scenario: The Pair — Act 2: DNS Black Hole (eBPF) demo trigger
#
# Usage:
#   ./trigger.sh start     # Apply DNSChaos SERVFAIL on accounts-service lookups
#   ./trigger.sh stop      # Remove DNSChaos (or let the 8m duration expire)
#   ./trigger.sh status    # Show whether the DNSChaos resource is active

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"

SCRIPT_DIR="$(dirname "$0")"
MANIFEST="${SCRIPT_DIR}/chaos-experiment.yaml"
NAMESPACE="relibank"
DNSCHAOS_NAME="the-pair-act2-dns-servfail"

_ensure_chaos_mesh() {
  # Idempotent Chaos Mesh helm install (containerd runtime for AKS)
  if kubectl get namespace chaos-mesh >/dev/null 2>&1 && kubectl get crds dnschaos.chaos-mesh.org >/dev/null 2>&1; then
    echo "✓ Chaos Mesh already installed"
    return 0
  fi

  echo "=== Installing Chaos Mesh via Helm ==="
  helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
  helm repo update
  helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace chaos-mesh \
    --create-namespace \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --wait
  echo "Chaos Mesh installed successfully"
}

usage() {
  echo "Usage: $0 <start|stop|status>"
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  start)
    # Ensure Chaos Mesh is installed
    _ensure_chaos_mesh

    # Deliberately vague marker: it must not reveal the DNS root cause the demo wants found via eBPF
    nr_set_context "platform" "Routine platform maintenance" "OPERATIONAL" \
        "Scheduled cluster maintenance window started" "ALL"
    nr_push_change_tracking

    echo "=== Applying DNSChaos (SERVFAIL on accounts-service lookups) ==="
    # Recreate: an expired DNSChaos stays in Stop/Recovered and ignores an unchanged re-apply
    kubectl delete -f "$MANIFEST" --ignore-not-found
    kubectl apply -f "$MANIFEST"
    echo "Active for ~8 minutes (duration) or until: ./trigger.sh stop"
    ;;

  stop)
    nr_set_context "platform" "Routine platform maintenance" "OPERATIONAL" \
        "Scheduled cluster maintenance window completed" "ALL"
    nr_push_change_tracking

    echo "=== Removing DNSChaos ==="
    kubectl delete -f "$MANIFEST" --ignore-not-found
    ;;

  status)
    echo "=== DNSChaos ==="
    kubectl get dnschaos "$DNSCHAOS_NAME" -n "$NAMESPACE" 2>/dev/null || echo "No DNSChaos resource active"
    ;;

  *)
    usage
    ;;
esac
