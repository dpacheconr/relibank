#!/usr/bin/env bash
# Scenario: The Pair — Act 1: Cloud Drift (Azure NSG adaptation)
#
# Azure NSG deny rule + CoreDNS starvation.
#
# This trigger performs two related failures:
#   1. Adds a deny NSG rule to the AKS node resource group NSG,
#      blocking inbound traffic to the cluster (simulates a network
#      misconfiguration at the Azure layer, visible in Activity Log).
#   2. Injects CPU/memory stress on CoreDNS pods, starving DNS resolution
#      for in-cluster service discovery.
#
# Usage:
#   ./trigger.sh start    — Add NSG deny rule + stress CoreDNS
#   ./trigger.sh stop     — Remove NSG deny rule, remove CoreDNS stress
#   ./trigger.sh status   — Report current state
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/chaos-experiment.yaml"
NAMESPACE="relibank"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-relibank-rg}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:?set AKS_CLUSTER_NAME}"
NSG_DENY_RULE_NAME="act1-deny-ingress-ports"
# NSG rule priority: Azure NSG priorities range 100–4096 (lower number wins).
# AKS cloud-provider LB rules start ~500, platform defaults are 65000+.
# Priority 200 beats LB-allow rules (intended break) and is scoped to TCP 80/443
# from Internet source, so kubelet, intra-VNet, and AzureLoadBalancer-tag probes untouched.
NSG_PRIORITY="200"

_ensure_chaos_mesh() {
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

_usage() {
    cat <<EOF
Usage: $0 {start|stop|status}

  start   — Add NSG deny rule to AKS node RG; inject CoreDNS stress (duration: 10 minutes)
  stop    — Remove NSG deny rule; remove CoreDNS stress
  status  — Report NSG rule and CoreDNS stress state

Environment:
  AZURE_RESOURCE_GROUP   — Resource group containing the AKS cluster (default: relibank-rg)
  AKS_CLUSTER_NAME       — AKS cluster name (required)

Examples:
  ./trigger.sh start
  ./trigger.sh status
  ./trigger.sh stop
EOF
    exit 1
}

[[ $# -lt 1 ]] && _usage
CMD="$1"

# Verify kubectl connectivity and namespace
if ! kubectl get pods -n "$NAMESPACE" -o name >/dev/null 2>&1; then
    echo "ERROR: Namespace '$NAMESPACE' not found. Check cluster connectivity." >&2
    exit 1
fi

# Helper: Get the AKS node resource group
_get_node_resource_group() {
    az aks show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --query "nodeResourceGroup" -o tsv 2>/dev/null || echo ""
}

# Helper: Get the primary NSG in the node resource group
_get_node_nsg() {
    local node_rg="$1"
    az network nsg list \
        --resource-group "$node_rg" \
        --query "[0].name" -o tsv 2>/dev/null || echo ""
}

# Helper: Check if NSG deny rule exists
_nsg_rule_exists() {
    local node_rg="$1"
    local nsg_name="$2"
    az network nsg rule show \
        --resource-group "$node_rg" \
        --nsg-name "$nsg_name" \
        --name "$NSG_DENY_RULE_NAME" &>/dev/null && echo "true" || echo "false"
}

# Helper: Check if CoreDNS stress is active
_coredns_stress_active() {
    kubectl get stresschaos "act1-coredns-starvation" -n "$NAMESPACE" &>/dev/null && echo "true" || echo "false"
}

# Helper: Report state
_report_status() {
    local node_rg nsg_name nsg_rule_state stress_state
    node_rg=$(_get_node_resource_group)
    nsg_name=$(_get_node_nsg "$node_rg")
    nsg_rule_state=$(_nsg_rule_exists "$node_rg" "$nsg_name")
    stress_state=$(_coredns_stress_active)

    echo "=== Act 1: Cloud Drift Status ==="
    echo "Node Resource Group: ${node_rg:-unknown}"
    echo "Node NSG: ${nsg_name:-unknown}"
    echo "NSG deny rule active: ${nsg_rule_state}"
    echo "CoreDNS stress active: ${stress_state}"

    if [[ "$nsg_rule_state" == "true" ]] && [[ "$stress_state" == "true" ]]; then
        echo "Status: ACTIVE (NSG block + stress in effect)"
    elif [[ "$nsg_rule_state" == "false" ]] && [[ "$stress_state" == "false" ]]; then
        echo "Status: RESTORED (baseline)"
    else
        echo "Status: PARTIAL (misconfigured)"
    fi
}

case "$CMD" in
    start)
        # Ensure Chaos Mesh is installed
        _ensure_chaos_mesh

        local node_rg nsg_name
        node_rg=$(_get_node_resource_group)
        [[ -z "$node_rg" ]] && { echo "ERROR: Could not determine node resource group" >&2; exit 1; }
        
        nsg_name=$(_get_node_nsg "$node_rg")
        [[ -z "$nsg_name" ]] && { echo "ERROR: Could not find NSG in node resource group $node_rg" >&2; exit 1; }

        echo "[Act 1] Starting Cloud Drift scenario..."

        # Step 1: Add NSG deny rule (scoped to ingress ports)
        echo "[Act 1] Adding NSG deny rule to block inbound HTTP/HTTPS traffic..."
        if az network nsg rule create \
            --resource-group "$node_rg" \
            --nsg-name "$nsg_name" \
            --name "$NSG_DENY_RULE_NAME" \
            --priority "$NSG_PRIORITY" \
            --direction Inbound \
            --access Deny \
            --protocol Tcp \
            --source-address-prefixes Internet \
            --destination-port-ranges 80 443 \
            --destination-address-prefixes '*' \
            --output none 2>/dev/null; then
            echo "[Act 1] ✓ NSG deny rule added (blocks HTTP/HTTPS from internet)"
        else
            echo "[Act 1] ✗ Failed to add NSG deny rule" >&2
            exit 1
        fi
        sleep 2

        # Step 2: Apply CoreDNS StressChaos
        echo "[Act 1] Injecting CoreDNS CPU/memory stress..."
        if kubectl apply -f "$MANIFEST" &>/dev/null; then
            echo "[Act 1] ✓ CoreDNS StressChaos applied (duration: 10 minutes)"
        else
            echo "[Act 1] ✗ Failed to apply CoreDNS StressChaos" >&2
            exit 1
        fi

        echo ""
        echo "[Act 1] Scenario active. Expected behavior:"
        echo "  - Inbound HTTP/HTTPS traffic blocked by NSG rule (visible in Azure Activity Log)"
        echo "  - External requests timeout; internal cluster traffic unaffected"
        echo "  - In-cluster DNS queries start timing out (~30-60s) due to CoreDNS stress"
        echo "  - APM shows service-to-service latency spike (internal cluster services)"
        echo "  - CoreDNS pods CPU/memory maxed out"
        echo "  - Kubernetes 360 shows all pods Running (no pod failures)"
        echo ""
        echo "Next steps:"
        echo "  1. Observe APM latency/error spike in New Relic (2-3 min)"
        echo "  2. Check K8s 360 → CoreDNS CPU/memory resource pressure"
        echo "  3. Check Azure Activity Log for NSG rule change"
        echo "  4. Run 'trigger.sh status' to confirm active state"
        echo "  5. Run 'trigger.sh stop' to restore (or wait ~10 min for auto-expire)"
        ;;

    stop)
        echo "[Act 1] Stopping Cloud Drift scenario..."

        local node_rg nsg_name
        node_rg=$(_get_node_resource_group)
        [[ -z "$node_rg" ]] && { echo "ERROR: Could not determine node resource group" >&2; exit 1; }

        nsg_name=$(_get_node_nsg "$node_rg")
        [[ -z "$nsg_name" ]] && { echo "ERROR: Could not find NSG in node resource group $node_rg" >&2; exit 1; }

        # Step 1: Remove NSG deny rule
        echo "[Act 1] Removing NSG deny rule..."
        if az network nsg rule delete \
            --resource-group "$node_rg" \
            --nsg-name "$nsg_name" \
            --name "$NSG_DENY_RULE_NAME" \
            --output none 2>/dev/null; then
            echo "[Act 1] ✓ NSG deny rule removed"
        else
            echo "[Act 1] ✗ Failed to remove NSG deny rule" >&2
            exit 1
        fi
        sleep 2

        # Step 2: Remove CoreDNS StressChaos
        echo "[Act 1] Removing CoreDNS stress..."
        if kubectl delete -f "$MANIFEST" --ignore-not-found 2>/dev/null; then
            echo "[Act 1] ✓ CoreDNS StressChaos removed"
        else
            echo "[Act 1] ✗ Failed to remove CoreDNS StressChaos" >&2
            exit 1
        fi

        echo ""
        echo "[Act 1] Scenario stopped. Recovery in progress:"
        echo "  - HTTP/HTTPS inbound traffic unblocked (NSG rule removed)"
        echo "  - DNS resolution recovering (~30-60s) as CoreDNS stress ends"
        echo "  - CoreDNS CPU/memory pressure subsiding"
        echo "  - Note: AKS may reconcile NSG managed rules if they were affected"
        ;;

    status)
        _report_status
        ;;

    *)
        echo "ERROR: Unknown command '$CMD'" >&2
        _usage
        ;;
esac
