#!/usr/bin/env bash
# GitOps Failure — Shift-Left Compliance Failure demo trigger
#
# Usage:
#   ./trigger.sh create-pr     # Create bad-PR branch + patch + push + open GH PR
#   ./trigger.sh merge         # Force-merge the PR (CVE dependency lands on base)
#   ./trigger.sh rollback      # Revert, restore requirements.txt, clean up branch
#   ./trigger.sh status        # Show current branch / PR state
#
# Subcommand for S8 CVE surface:
#   ./trigger.sh cve-only      # Apply just the CVE requirements patch (no Terraform)
#   ./trigger.sh cve-restore   # Restore original requirements.txt

set -euo pipefail

# shellcheck source=../lib/nr-scenario.sh
source "$(dirname "$0")/../lib/nr-scenario.sh"

# Load .env from repo root if present (provides NR_ACCOUNT_ID, NR_USER_API_KEY, etc.)
REPO_ROOT_ENV="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/.env"
# shellcheck disable=SC1090
[[ -f "$REPO_ROOT_ENV" ]] && set -a && source "$REPO_ROOT_ENV" && set +a

DEMO_BRANCH="${DEMO_BRANCH:-demo/gitops-failure-bad-pr}"
SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

usage() {
  echo "Usage: $0 <create-pr|merge|rollback|status|cve-only|cve-restore>"
  exit 1
}

[[ $# -lt 1 ]] && usage

case "$1" in
  create-pr)
    nr_set_context "2" "Bad PR" "GOVERNANCE" \
        "Shift-left gate: bad Terraform tags + CVE dependency detected in PR" "APM"
    nr_push_change_tracking

    echo "=== Creating demo branch: ${DEMO_BRANCH} ==="
    git -C "$REPO_ROOT" checkout -b "$DEMO_BRANCH"

    # Only the CVE requirements.txt swap is needed to reproduce the PR-gate failure.
    echo "=== Installing CVE requirements ==="
    cp "${SCRIPT_DIR}/requirements-with-cve.txt" \
       "${REPO_ROOT}/support_service/requirements.txt"

    echo "=== Committing ==="
    git -C "$REPO_ROOT" add support_service/requirements.txt
    git -C "$REPO_ROOT" commit -m \
      "feat: bump payment-gateway-service dep [DEMO — CVE dep]"
    git -C "$REPO_ROOT" push origin "$DEMO_BRANCH"

    echo "=== Opening PR ==="
    gh pr create \
      --repo "$(git -C "$REPO_ROOT" remote get-url origin)" \
      --title "Bump support_service dependency [DEMO]" \
      --body "Demo scenario — shift-left CVE gate. Targets rumo-demo, never main." \
      --base rumo-demo \
      --head "$DEMO_BRANCH"

    echo ""
    echo "PR is open. It adds untagged/CVE-pinned dependency changes; nothing blocks it automatically."
    echo "To proceed to merge: ./trigger.sh merge"
    ;;

  merge)
    nr_set_context "2" "Bad PR Force-Merge" "GOVERNANCE" \
        "Force-merged non-compliant PR: missing team tag + CVE dep landed in main" "APM"
    nr_push_change_tracking

    echo "=== Force-merging PR (bypassing branch protection) ==="
    gh pr merge --squash --admin "$DEMO_BRANCH" \
      --repo "$(git -C "$REPO_ROOT" remote get-url origin)"

    echo ""
    echo "CVE dependency change is now on the base branch."
    echo "To restore: ./trigger.sh rollback"
    ;;

  rollback)
    nr_set_context "2" "Bad PR Rollback" "GOVERNANCE" \
        "Reverted force-merged PR: mis-tagged resource removed, compliance restored" "APM"
    nr_push_change_tracking

    echo "=== Reverting on rumo-demo ==="
    git -C "$REPO_ROOT" checkout rumo-demo
    MERGE_SHA=$(git -C "$REPO_ROOT" log --merges -1 --format="%H")
    git -C "$REPO_ROOT" revert --no-edit "$MERGE_SHA"
    git -C "$REPO_ROOT" push origin rumo-demo

    echo "=== Restoring requirements.txt ==="
    git -C "$REPO_ROOT" checkout HEAD -- support_service/requirements.txt

    echo "=== Cleaning up branch ==="
    git -C "$REPO_ROOT" branch -D "$DEMO_BRANCH" 2>/dev/null || true
    git -C "$REPO_ROOT" push origin --delete "$DEMO_BRANCH" 2>/dev/null || true

    echo "Done."
    ;;

  cve-only)
    nr_set_context "8" "CVE Dependency" "SECURITY" \
        "CVE dependency introduced: requests==2.18.0 (CVE-2018-18074, CVE-2023-32681)" "APM"
    nr_push_change_tracking

    echo "=== Installing CVE requirements (S8 surface) ==="
    cp "${SCRIPT_DIR}/requirements-with-cve.txt" \
       "${REPO_ROOT}/support_service/requirements.txt"
    echo "Done. requirements.txt now contains requests==2.18.0"
    echo "To restore: ./trigger.sh cve-restore"
    ;;

  cve-restore)
    nr_set_context "8" "CVE Dependency Remediated" "SECURITY" \
        "Vulnerable dependency removed: requests pinned to safe version" "APM"
    nr_push_change_tracking

    echo "=== Restoring requirements.txt ==="
    git -C "$REPO_ROOT" checkout HEAD -- support_service/requirements.txt
    echo "Done."
    ;;

  status)
    echo "=== Current Branch ==="
    git -C "$REPO_ROOT" branch --show-current

    echo ""
    echo "=== Demo Branch State ==="
    git -C "$REPO_ROOT" show-ref "refs/remotes/origin/${DEMO_BRANCH}" 2>/dev/null \
      && echo "Remote branch exists" || echo "Remote branch not found"

    echo ""
    echo "=== Open PRs ==="
    gh pr list --repo "$(git -C "$REPO_ROOT" remote get-url origin)" \
      --head "$DEMO_BRANCH" 2>/dev/null || echo "No open PRs for ${DEMO_BRANCH}"
    ;;

  *)
    usage
    ;;
esac
