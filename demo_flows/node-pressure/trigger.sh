#!/usr/bin/env bash
# Node Pressure demo trigger (AKS adaptation)
#
# Usage:
#   ./trigger.sh start    # Scale the AKS node pool 3 -> 2 via the AKS API + inject memory stress
#   ./trigger.sh stop     # Remove the stress + scale the node pool back to 3
#   ./trigger.sh status   # Show node pool size, nodes, chaos state, pod health
#
# The scale change goes through the AKS API so it is recorded by Azure Activity Log.
#
# Required environment:
#   kubectl configured for the AKS cluster
#   Azure CLI credentials with permission to scale AKS node pools
#   Optional: AZURE_RESOURCE_GROUP (default relibank-rg), AKS_CLUSTER_NAME (required),
#             AKS_NODEPOOL_NAME (default nodepool1), NP_NODES_NORMAL/NP_NODES_REDUCED (3/2)

set -euo pipefail

# shellcheck source=../lib/nr-scenario.sh
source "$(dirname "$0")/../lib/nr-scenario.sh"

SCRIPT_DIR="$(dirname "$0")"
EXPERIMENT="${SCRIPT_DIR}/chaos-experiment.yaml"
NAMESPACE="relibank"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-relibank-rg}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:?set AKS_CLUSTER_NAME}"
AKS_NODEPOOL_NAME="${AKS_NODEPOOL_NAME:-nodepool1}"
NODES_NORMAL="${NP_NODES_NORMAL:-3}"
NODES_REDUCED="${NP_NODES_REDUCED:-2}"

usage() {
  echo "Usage: $0 <start|stop|status>"
  exit 1
}

ensure_chaos_mesh() {
  # Idempotent Chaos Mesh helm install (containerd runtime for AKS)
  if kubectl get namespace chaos-mesh >/dev/null 2>&1 && kubectl get crds stresschaos.chaos-mesh.org >/dev/null 2>&1; then
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

scale_nodepool() {
  # $1 = desired count
  # Apply labels to node pool so pods pinned by chaos-target / noisy-neighbor nodeSelectors
  # never lose their labelled node pool.
  az aks nodepool update \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --cluster-name "$AKS_CLUSTER_NAME" \
    --name "$AKS_NODEPOOL_NAME" \
    --tags "chaos-target=true" "noisy-neighbor=true" \
    --no-wait

  az aks nodepool scale \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --cluster-name "$AKS_CLUSTER_NAME" \
    --name "$AKS_NODEPOOL_NAME" \
    --node-count "$1"
}

[[ $# -lt 1 ]] && usage

case "$1" in
  start)
    # 0. Ensure Chaos Mesh is installed
    ensure_chaos_mesh

    # 1. Set NR scenario context and fire Change Tracking marker first
    nr_set_context "10" "Node Memory Pressure" "INFRASTRUCTURE" \
        "AKS node pool scaled ${NODES_NORMAL}→${NODES_REDUCED} (cost reduction): memory over-commitment across all services" "ALL"
    nr_push_change_tracking

    # 2. Scale the node pool down through the AKS API (recorded in Azure Activity Log)
    echo "=== Scaling AKS node pool ${AKS_NODEPOOL_NAME}: desired ${NODES_NORMAL} → ${NODES_REDUCED} ==="
    scale_nodepool "$NODES_REDUCED"
    echo "Node pool scale submitted to AKS (takes ~2-3 minutes to drain)."

    # Wait for the scale-down to finish and evicted pods to land on the remaining nodes.
    # StressChaos only injects into pods that exist when it is applied; pods rescheduled
    # afterwards would run unstressed.
    echo "Waiting for node count ${NODES_REDUCED} and relibank pods Running (max 200s)..."
    for _ in $(seq 1 40); do
      nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
      not_running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -vcE 'Running|Completed' || true)
      [[ "$nodes" -le "$NODES_REDUCED" && "$not_running" -eq 0 ]] && break
      sleep 5
    done
    echo "Nodes Ready: ${nodes:-?}, pods not Running: ${not_running:-?}"

    # Pods recreated while the agent operator was itself rescheduled are admitted without the
    # APM agent (webhook unreachable). Wait for the operator, then restart any annotated
    # deployment whose pod has no nri-python init container.
    kubectl rollout status deployment/k8s-agents-operator -n newrelic --timeout=90s 2>/dev/null || true
    for d in $(kubectl get deploy -n "$NAMESPACE" -o jsonpath='{range .items[?(@.spec.template.metadata.annotations.instrumentation\.newrelic\.com/inject-python=="true")]}{.metadata.name}{"\n"}{end}'); do
      inits=$(kubectl get pods -n "$NAMESPACE" -l "app=$d" -o jsonpath='{.items[*].spec.initContainers[*].name}' 2>/dev/null)
      if [[ "$inits" != *nri-python* ]]; then
        echo "Re-injecting APM agent: restarting $d"
        kubectl rollout restart "deployment/$d" -n "$NAMESPACE"
      fi
    done
    for _ in $(seq 1 24); do
      not_running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -vcE 'Running|Completed' || true)
      [[ "$not_running" -eq 0 ]] && break
      sleep 5
    done

    # 3. Inject memory stress across every relibank service pod (no single culprit)
    echo ""
    echo "=== Applying Chaos Mesh memory stress (every relibank service pod) ==="
    kubectl apply -f "$EXPERIMENT"

    echo ""
    echo "Node Pressure active. Expected degradation timeline:"
    echo "  T+0s:   Azure Activity Log + NR Change Tracking: node pool scaled ${NODES_NORMAL}→${NODES_REDUCED}"
    echo "  T+90s:  Infra 360 → memory pressure on the remaining nodes"
    echo "  T+3-5m: K8s 360 → pod evictions / OOMKilled containers"
    echo "  T+5-8m: APM → bill-pay p95 latency > 2s, error rate climbs"
    echo ""
    echo "To restore: ./trigger.sh stop"
    ;;

  stop)
    nr_set_context "10" "Node Memory Pressure Resolved" "INFRASTRUCTURE" \
        "AKS node pool restored ${NODES_REDUCED}→${NODES_NORMAL}: memory pressure relieved, chaos removed" "ALL"
    nr_push_change_tracking

    echo "=== Removing Chaos Mesh memory stress ==="
    kubectl delete -f "$EXPERIMENT" --ignore-not-found

    echo ""
    echo "=== Restoring AKS node pool: desired ${NODES_REDUCED} → ${NODES_NORMAL} ==="
    scale_nodepool "$NODES_NORMAL"
    echo "Node pool restore submitted. Nodes will rejoin within ~2-3 minutes."

    echo ""
    echo "Recovery check:"
    echo "  kubectl get nodes -w"
    echo "  kubectl get pods -n relibank | grep -v Running"
    ;;

  status)
    echo "=== AKS Node Pool ==="
    az aks nodepool show \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --cluster-name "$AKS_CLUSTER_NAME" \
      --name "$AKS_NODEPOOL_NAME" \
      --query '{name:name,count:count,vmSize:vmSize}' \
      --output table 2>/dev/null || echo "node pool show unavailable (no Azure credentials)"

    echo ""
    echo "=== AKS Nodes ==="
    kubectl get nodes \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory

    echo ""
    echo "=== Active StressChaos ==="
    kubectl get stresschaos -n "$NAMESPACE" 2>/dev/null || echo "No StressChaos resources"

    echo ""
    echo "=== Pod Health ==="
    kubectl get pods -n "$NAMESPACE" \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount \
      | sort -k2

    echo ""
    echo "=== OOMKilled events (last 10) ==="
    kubectl get events -n "$NAMESPACE" \
      --field-selector reason=OOMKilling \
      --sort-by='.lastTimestamp' 2>/dev/null | tail -10 \
      || echo "No OOMKill events"
    ;;

  *)
    usage
    ;;
esac
