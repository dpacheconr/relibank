#!/usr/bin/env bash
# The Exposure Act 1 — Vulnerable Dependency Silent Exposure demo trigger
#
# Usage:
#   ./trigger.sh cve-only      # Flip support-service to the pre-built vulnerable image
#   ./trigger.sh cve-restore   # Roll support-service back to the prior image

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"

# Load .env from repo root if present (provides NR_ACCOUNT_ID, NR_USER_API_KEY, etc.)
# nounset is disabled while sourcing: .env may contain unquoted values with a
# literal '$' (e.g. in a generated secret) that would otherwise trip set -u
# during variable expansion, even though the value itself is harmless.
REPO_ROOT_ENV="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/.env"
# shellcheck disable=SC1090
if [[ -f "$REPO_ROOT_ENV" ]]; then
  set +u
  set -a
  source "$REPO_ROOT_ENV"
  set +a
  set -u
fi

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
NAMESPACE="${NR_SCENARIO_NAMESPACE:-relibank}"
VULN_TAG="cve-2018-18074"

usage() {
  echo "Usage: $0 <cve-only|cve-restore>"
  exit 1
}

[[ $# -lt 1 ]] && usage

# Sends a real NerdGraph changeTrackingCreateEvent for this deployment action.
# nr_push_change_tracking() (demo_flows/lib/nr-scenario.sh) depends on an ArgoCD
# PostSync hook that isn't running on this cluster, so it's a no-op here — this
# talks to NerdGraph directly instead.
nr_push_deployment_marker() {
  local version="$1"
  local short_description="$2"

  if [[ -z "${NR_USER_API_KEY:-}" || -z "${NR_ACCOUNT_ID:-}" ]]; then
    echo "[nr-scenario] WARNING: NR_USER_API_KEY/NR_ACCOUNT_ID not set — skipping change tracking marker."
    return 0
  fi

  python3 "${REPO_ROOT}/utils/scripts/new_relic/send_change_tracking_marker.py" \
    --api-key "${NR_USER_API_KEY}" \
    --account-id "${NR_ACCOUNT_ID}" \
    --app-name "${APP_NAME:-relibank} - Support Service" \
    --entity-domain APM \
    --category DEPLOYMENT \
    --type ROLLING \
    --version "${version}" \
    --user "demo-scenario-runner" \
    --short-description "${short_description}" \
    --custom-attribute scenario=10 \
    --custom-attribute change_category=security \
    || echo "[nr-scenario] WARNING: change tracking marker failed to send — demo continues."
}

case "$1" in
  cve-only)
    nr_set_context "10" "CVE Dependency" "SECURITY" \
        "CVE dependency introduced: requests==2.18.0 (CVE-2018-18074, CVE-2023-32681)" "APM"

    echo "=== Swapping support-service to vulnerable image (${VULN_TAG}) ==="
    CURRENT_IMAGE=$(kubectl get deployment support-service -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    IMAGE_REPO="${CURRENT_IMAGE%:*}"
    kubectl set image deployment/support-service \
        support-service="${IMAGE_REPO}:${VULN_TAG}" -n "$NAMESPACE"
    kubectl rollout status deployment/support-service -n "$NAMESPACE" --timeout=60s

    nr_push_deployment_marker "${VULN_TAG}" \
        "Introduced requests==2.18.0 (CVE-2018-18074, CVE-2023-32681) on support-service"

    echo "Done. support-service is now running requests==2.18.0."
    echo "To restore: ./trigger.sh cve-restore"
    ;;

  cve-restore)
    nr_set_context "10" "CVE Dependency Remediated" "SECURITY" \
        "Vulnerable dependency removed: requests pinned to safe version" "APM"

    echo "=== Restoring support-service to previous image ==="
    kubectl rollout undo deployment/support-service -n "$NAMESPACE"
    kubectl rollout status deployment/support-service -n "$NAMESPACE" --timeout=60s

    RESTORED_IMAGE=$(kubectl get deployment support-service -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    nr_push_deployment_marker "${RESTORED_IMAGE##*:}" \
        "Remediated CVE-2018-18074/CVE-2023-32681 by reverting support-service's requests dependency"

    echo "Done."
    ;;

  *)
    usage
    ;;
esac
