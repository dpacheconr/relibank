#!/usr/bin/env bash
# The Exposure: Vulnerable Dependency Silent Exposure (Multi-layer CVE correlation)
#
# Unified coordinator for Act 1 (supply-chain CVE) and Act 2 (node-level CVE).
# Uses New Relic Infrastructure agent for node-level findings.
#
# Usage:
#   ./trigger.sh cve-only       # Introduce supply-chain CVE in support-service (Act 1)
#   ./trigger.sh cve-restore    # Remove supply-chain CVE from support-service (Act 1)
#   ./trigger.sh scan-layers    # Verify Infrastructure agent reports on nodes + Security RX guidance (Act 2)
#   ./trigger.sh cross-layer    # Query NR for APM + Infrastructure Host entity correlation
#   ./trigger.sh status         # Aggregate status from both acts

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# Source common NR functions
# shellcheck disable=SC1090
source "$REPO_ROOT/demo_flows/lib/nr-scenario.sh" || {
  cat >&2 <<EOF
[ERROR] Could not source demo_flows/lib/nr-scenario.sh
Make sure you are running from repo root: cd $REPO_ROOT
EOF
  exit 1
}

# Load .env from repo root (provides NR_ACCOUNT_ID, NR_USER_API_KEY, etc.)
REPO_ROOT_ENV="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/.env"
# shellcheck disable=SC1090
if [[ -f "$REPO_ROOT_ENV" ]]; then
  set +u
  set -a
  source "$REPO_ROOT_ENV"
  set +a
  set -u
fi

NAMESPACE="${NR_SCENARIO_NAMESPACE:-relibank}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:?set AKS_CLUSTER_NAME}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-relibank-rg}"
NR_ACCOUNT_ID="${NR_ACCOUNT_ID:-}"

usage() {
  cat >&2 <<EOF
Usage: $0 <cve-only|cve-restore|scan-layers|cross-layer|status>

  cve-only      — Introduce supply-chain CVE (requests==2.18.0) in support-service (Act 1)
  cve-restore   — Remove supply-chain CVE from support-service (Act 1)
  scan-layers   — Verify Infrastructure agent, report node OS-IMAGE + Security RX guidance (Act 2)
  cross-layer   — Query NR for APM + Infrastructure Host entity CVE correlation
  status        — Aggregate status from both acts
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  cve-only)
    echo "[the-exposure] Delegating to Act 1 (supply-chain CVE)..."
    "$SCRIPT_DIR/act-1-supply-chain-cve/trigger.sh" cve-only
    ;;

  cve-restore)
    echo "[the-exposure] Delegating to Act 1 (supply-chain CVE remediation)..."
    "$SCRIPT_DIR/act-1-supply-chain-cve/trigger.sh" cve-restore
    ;;

  scan-layers)
    echo "[the-exposure] Starting multi-layer CVE scan..."

    # Act 1: Supply-chain scan (APM-side dependency analysis)
    echo ""
    echo "[the-exposure] Act 1: Checking APM application for supply-chain CVEs..."
    if kubectl get deployment support-service -n "$NAMESPACE" &>/dev/null; then
      VULN_TAG="cve-2018-18074"
      CURRENT_IMAGE=$(kubectl get deployment support-service -n "$NAMESPACE" \
          -o jsonpath='{.spec.template.spec.containers[0].image}')
      IMAGE_REPO="${CURRENT_IMAGE%:*}"
      IMAGE_TAG="${CURRENT_IMAGE##*:}"

      # Report current image status
      if [[ "$IMAGE_TAG" == "$VULN_TAG" ]]; then
        echo "[the-exposure] ✓ support-service running vulnerable image: ${IMAGE_REPO}:${VULN_TAG}"
      else
        echo "[the-exposure] ℹ support-service running: ${IMAGE_REPO}:${IMAGE_TAG} (not CVE pinned)"
      fi
    else
      echo "[the-exposure] WARNING: support-service not found"
    fi

    # Act 2: Node-level Infrastructure agent CVE reporting
    echo ""
    echo "[the-exposure] Act 2: Verifying Infrastructure agent reports on AKS nodes..."
    "$SCRIPT_DIR/act-2-node-level-cve/trigger.sh" start

    echo ""
    echo "[the-exposure] Multi-layer scan initiated."
    echo "Poll findings with: $0 cross-layer"
    ;;

  cross-layer)
    echo "[the-exposure] Querying NR for cross-layer CVE correlation..."

    # Report Act 2 findings from NR (Infrastructure agent → NR Vulnerabilities)
    echo "[the-exposure] Querying Infrastructure host CVEs from New Relic..."
    "$SCRIPT_DIR/act-2-node-level-cve/trigger.sh" status 2>&1 || true

    echo ""
    echo "[the-exposure] NR Correlation Guidance:"
    echo "  APM (support-service) Vulnerabilities: navigate to Security > Vulnerabilities, filter by support-service entity"
    echo "  Infrastructure (node) Vulnerabilities: navigate to Security > Vulnerabilities, filter by entity.domain = 'INFRA'"
    echo "  Host-App correlation via k8s_node_name tag: SELECT DISTINCT entity.name FROM Transaction WHERE tags.k8s_node_name = '<node>' SINCE 1 hour ago"
    echo ""
    if [[ -n "${NR_ACCOUNT_ID:-}" ]]; then
      echo "  NRQL builder: https://one.newrelic.com/nrql-builder?account=$NR_ACCOUNT_ID"
    fi
    ;;

  status)
    echo "[the-exposure] Status report:"
    echo ""

    # Act 1 status
    echo "[the-exposure] Act 1 (Supply-Chain CVE):"
    if kubectl get deployment support-service -n "$NAMESPACE" &>/dev/null; then
      CURRENT_IMAGE=$(kubectl get deployment support-service -n "$NAMESPACE" \
          -o jsonpath='{.spec.template.spec.containers[0].image}')
      IMAGE_TAG="${CURRENT_IMAGE##*:}"
      echo "  support-service image tag: $IMAGE_TAG"
      if [[ "$IMAGE_TAG" == "cve-2018-18074" ]]; then
        echo "  Status: ✓ CVE-pinned (vulnerable)"
      else
        echo "  Status: ℹ Safe version (remediated)"
      fi
    else
      echo "  Status: WARNING - support-service not found"
    fi

    # Act 2 status
    echo ""
    echo "[the-exposure] Act 2 (Node-Level CVE via Infrastructure):"
    echo "  Cluster: $AKS_CLUSTER_NAME"
    echo "  For findings: Check NR Security > Vulnerabilities (Infrastructure domain)"
    ;;

  *)
    usage
    ;;
esac
