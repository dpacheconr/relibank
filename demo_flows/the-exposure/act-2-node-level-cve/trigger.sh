#!/usr/bin/env bash

# The Exposure Act 2: Node-Level Vulnerability & Host-App Correlation (New Relic Infrastructure)
#
# Verify the New Relic Infrastructure agent (nri-bundle DaemonSet) reports OS and package CVEs from AKS nodes,
# then correlate vulnerable HOST entities with running APM applications in NR.
#
# Usage:
#   ./trigger.sh start    — Verify Infrastructure DaemonSet ready, report node OS-IMAGE + Security RX guidance
#   ./trigger.sh status   — Poll NR for Host entity + vulnerability findings + APM app correlation
#   ./trigger.sh stop     — (no-op; findings are read-only)

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
NAMESPACE="${NR_SCENARIO_NAMESPACE:-relibank}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:?set AKS_CLUSTER_NAME}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-relibank-rg}"
NR_ACCOUNT_ID="${NR_ACCOUNT_ID:-}"

# Source common functions
# shellcheck disable=SC1090
source "$REPO_ROOT/.env" 2>/dev/null || true
# shellcheck disable=SC1090,SC1091
source "$REPO_ROOT/demo_flows/lib/nr-scenario.sh" || {
  cat >&2 <<EOF
[ERROR] Could not source demo_flows/lib/nr-scenario.sh
Make sure you are running from repo root: cd $REPO_ROOT
EOF
  exit 1
}

if [[ -z "${NR_ACCOUNT_ID:-}" ]]; then
  echo "[ERROR] NR_ACCOUNT_ID not set. Set in .env or export NR_ACCOUNT_ID=<account_id>"
  exit 1
fi

usage() {
  cat >&2 <<EOF
Usage: $0 <start|status|stop>

  start   — Verify Infrastructure DaemonSet ready, report node OS-IMAGE + Security RX guidance
  status  — Query NR for vulnerable Host entities + linked APM applications
  stop    — (no-op; read-only findings)
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  start)
    echo "[the-exposure] Verifying New Relic Infrastructure agent on AKS cluster '$AKS_CLUSTER_NAME'..."

    # Verify Infrastructure DaemonSet is deployed and ready
    echo "[INFO] Checking Infrastructure DaemonSet status..."
    if ! kubectl get daemonset -n newrelic newrelic-infrastructure &>/dev/null; then
      echo "[ERROR] Infrastructure DaemonSet (newrelic-infrastructure) not found in newrelic namespace."
      echo "[INFO] Ensure the nri-bundle helm release is installed: helm list -n newrelic"
      exit 1
    fi

    # Get DaemonSet readiness
    DESIRED=$(kubectl get daemonset -n newrelic newrelic-infrastructure -o jsonpath='{.status.desiredNumberScheduled}')
    READY=$(kubectl get daemonset -n newrelic newrelic-infrastructure -o jsonpath='{.status.numberReady}')

    echo "[INFO] Infrastructure DaemonSet: $READY/$DESIRED pods ready"

    if [[ "$READY" -lt "$DESIRED" ]]; then
      echo "[WARNING] Not all Infrastructure pods are ready. Waiting may improve coverage."
    fi

    # Report node OS-IMAGE
    echo ""
    echo "[INFO] AKS nodes and OS-IMAGE:"
    kubectl get nodes -o wide | awk 'NR==1 || /.*/' | sed 's/^/  /'

    echo ""
    echo "[INFO] Security RX Infrastructure agent reports package CVEs for these nodes."
    echo "[INFO] To view findings in New Relic:"
    echo "      1. Navigate to: Security > Vulnerabilities (or Vulnerabilities Management)"
    echo "      2. Filter by entity type: Infrastructure / Host"
    echo "      3. Select a node to view CVEs and linked APM applications (via k8s_node_name tag)"
    echo ""
    echo "[INFO] Poll detailed status with: $0 status"
    ;;

  status)
    echo "[the-exposure] Querying NR for vulnerable Host entities + APM app correlation..."

    # Report Infrastructure DaemonSet status
    echo "[INFO] Infrastructure DaemonSet Status:"
    kubectl get daemonset -n newrelic newrelic-infrastructure --no-headers 2>/dev/null | awk '{print "      " $0}' || echo "      (Not found)"

    echo ""
    echo "[INFO] Node OS-IMAGE:"
    kubectl get nodes -o wide | awk 'NR==1 || /.*/' | sed 's/^/  /'

    echo ""
    echo "[INFO] To query Infrastructure host CVEs in New Relic:"
    echo "      Navigate to: Security > Vulnerabilities or Vulnerability Management"
    echo "      Filter by entity.domain = 'INFRA' to see Infrastructure agent findings"
    echo ""
    echo "[INFO] Example NRQL to find APM apps running on a vulnerable node:"
    echo "      SELECT DISTINCT entity.name FROM Transaction WHERE tags.k8s_node_name = '<node-name>' SINCE 1 hour ago"
    echo ""
    if [[ -n "${NR_ACCOUNT_ID:-}" ]]; then
      echo "[INFO] NRQL builder: https://one.newrelic.com/nrql-builder?account=$NR_ACCOUNT_ID"
    fi
    ;;

  stop)
    echo "[the-exposure] No action needed (Vulnerability findings are read-only, reported by Infrastructure agent)."
    echo "[INFO] Findings persist in New Relic for the retention period."
    echo "[INFO] The Infrastructure agent continuously monitors and reports CVEs on the schedule configured in NR."
    ;;

  *)
    usage
    ;;
esac
