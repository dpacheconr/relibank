#!/usr/bin/env bash
# Shared helper for NR Change Tracking markers.
#
# Source this file, then call:
#   nr_set_context  <SCENARIO> <NAME> <CHANGE_TYPE> <DESCRIPTION> <TARGET_ENTITIES> [VERSION]
#   nr_push_change_tracking
#
# CHANGE_TYPE:      DEPLOYMENT | CHAOS | CONFIG | SECURITY | INFRASTRUCTURE | GOVERNANCE
# TARGET_ENTITIES:  APM | K8S_CLUSTER | INFRA_HOST | ALL
#
# nr_push_change_tracking() sends a real changeTrackingCreateEvent mutation to
# NerdGraph directly (utils/scripts/new_relic/send_change_tracking_marker.py).
#
# Requirements:
#   kubectl configured for the Kubernetes cluster
#   NR_USER_API_KEY + NR_ACCOUNT_ID (sourced from repo-root .env below, or
#   already exported in the environment)
#   python3 with `requests` installed, for send_change_tracking_marker.py

NR_SCENARIO_NAMESPACE="${NR_SCENARIO_NAMESPACE:-relibank}"
NR_SCENARIO_CM="${NR_SCENARIO_CM:-nr-scenario-context}"

# Anchor entity for change tracking markers. Not every TARGET_ENTITIES value
# (K8S_CLUSTER, INFRA_HOST, ALL) maps to an APM entity NerdGraph's
# changeTrackingCreateEvent can attach to directly, so every scenario's
# marker lands on this shared, always-on customer-facing entity instead of
# being dropped. Override per-invocation with NR_CHANGE_TRACKING_APP_NAME.
NR_CHANGE_TRACKING_APP_NAME="${NR_CHANGE_TRACKING_APP_NAME:-Bill Pay Service}"

# Load .env from repo root if present (provides NR_ACCOUNT_ID, NR_USER_API_KEY,
# etc.). nounset is disabled while sourcing: .env may contain unquoted values
# with a literal '$' that would otherwise trip set -u during expansion.
_NR_SCENARIO_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
_NR_REPO_ROOT_ENV="$(git -C "${_NR_SCENARIO_LIB_DIR}" rev-parse --show-toplevel 2>/dev/null)/.env"
if [[ -f "${_NR_REPO_ROOT_ENV}" ]]; then
  _nr_had_u=0
  case "$-" in *u*) _nr_had_u=1 ;; esac
  set +u
  set -a
  # shellcheck disable=SC1090
  source "${_NR_REPO_ROOT_ENV}"
  set +a
  [[ "${_nr_had_u}" -eq 1 ]] && set -u
  unset _nr_had_u
fi

nr_set_context() {
    local scenario="$1"
    local name="$2"
    local change_type="$3"
    local description="$4"
    local target_entities="$5"
    local version="${6:-$(git rev-parse --short HEAD 2>/dev/null || echo 'manual')}"

    echo "[nr-scenario] Setting context: scenario=${scenario} name=${name} type=${change_type} target=${target_entities}"
    echo "[nr-scenario]   description: ${description}"

    # Stashed for nr_push_change_tracking (called with no args right after).
    _NR_CTX_SCENARIO="${scenario}"
    _NR_CTX_NAME="${name}"
    _NR_CTX_CHANGE_TYPE="${change_type}"
    _NR_CTX_DESCRIPTION="${description}"
    _NR_CTX_TARGET_ENTITIES="${target_entities}"
    _NR_CTX_VERSION="${version}"

    if kubectl patch configmap "${NR_SCENARIO_CM}" \
        -n "${NR_SCENARIO_NAMESPACE}" \
        --type merge \
        -p "$(cat <<EOF
{
  "data": {
    "SCENARIO": "${scenario}",
    "SCENARIO_NAME": "${name}",
    "CHANGE_TYPE": "${change_type}",
    "CHANGE_DESCRIPTION": "${description}",
    "TARGET_ENTITIES": "${target_entities}",
    "CHANGE_VERSION": "${version}"
  }
}
EOF
)" 2>/dev/null; then
        echo "[nr-scenario] ConfigMap patched."
    else
        echo "[nr-scenario] WARNING: kubectl not reachable — skipping ConfigMap patch (demo continues)."
    fi
}

# Maps our internal CHANGE_TYPE label onto NerdGraph's changeTrackingCreateEvent
# category/type enum, which has no CHAOS/CONFIG/SECURITY/INFRASTRUCTURE/
# GOVERNANCE categories of its own. DEPLOYMENT passes through; everything
# else becomes an OPERATIONAL/OTHER event with the original label preserved
# as a custom attribute.
_nr_change_type_to_category() {
    case "$1" in
        DEPLOYMENT) echo "DEPLOYMENT ROLLING" ;;
        *) echo "OPERATIONAL OTHER" ;;
    esac
}

relibank_base_url() {
    # Resolve ReliBank's base URL from multiple sources, in priority order:
    # 1. $BASE_URL environment variable (if set)
    # 2. Terraform blue/green ingress hostname: main-ingress in default namespace
    # 3. ingress-nginx service public IP (AKS ingress controller)
    # 4. Legacy ingress hostname (fallback for older deployments)

    if [[ -n "${BASE_URL:-}" ]]; then
        echo "${BASE_URL}"
        return 0
    fi

    # Try main-ingress in default namespace (Terraform blue/green)
    local host
    host=$(kubectl get ingress main-ingress -n default -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    if [[ -n "$host" ]]; then
        echo "http://$host"
        return 0
    fi

    # Try ingress-nginx service public IP (AKS)
    local ip
    ip=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$ip" ]]; then
        echo "http://$ip"
        return 0
    fi

    # Fallback to legacy ingress hostname (older deployments)
    kubectl get ingress relibank-ingress -n relibank -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo ""
}

nr_push_change_tracking() {
    if [[ -z "${_NR_CTX_SCENARIO:-}" ]]; then
        echo "[nr-scenario] WARNING: nr_push_change_tracking called before nr_set_context — skipping."
        return 0
    fi

    if [[ -z "${NR_USER_API_KEY:-}" || -z "${NR_ACCOUNT_ID:-}" ]]; then
        echo "[nr-scenario] WARNING: NR_USER_API_KEY/NR_ACCOUNT_ID not set — skipping change tracking marker."
        return 0
    fi

    read -r _nr_category _nr_type <<< "$(_nr_change_type_to_category "${_NR_CTX_CHANGE_TYPE}")"

    local repo_root
    repo_root="$(git -C "${_NR_SCENARIO_LIB_DIR}" rev-parse --show-toplevel)"

    echo "[nr-scenario] Sending NerdGraph change tracking marker directly (category=${_nr_category})..."

    # Neutral by default: the marker must not reveal the scenario's root cause to the audience.
    # NR_MARKER_NEUTRAL=0 sends the real name/description/attributes (for stories that rely on the marker).
    local _nr_short="Routine platform maintenance" _nr_desc="Scheduled cluster maintenance window started" _nr_attrs=()
    # Start vs end is inferred from the caller's wording (ponytail: keyword heuristic, make it an explicit arg if it misfires)
    if printf '%s %s' "${_NR_CTX_NAME}" "${_NR_CTX_DESCRIPTION}" | tr '[:upper:]' '[:lower:]' \
        | grep -qE 'resolved|reset|fix|cleanup|clean up|rollback|rolled back|remediat|right-sized|restored|removed|completed|disabled|stopped'; then
        _nr_desc="Scheduled cluster maintenance window completed"
    fi
    [[ "${NR_MARKER_NEUTRAL:-1}" != "0" ]] && { _nr_category="OPERATIONAL"; _nr_type="OTHER"; }
    if [[ "${NR_MARKER_NEUTRAL:-1}" == "0" ]]; then
        _nr_short="${_NR_CTX_NAME}"
        _nr_desc="${_NR_CTX_DESCRIPTION}"
        _nr_attrs=(--custom-attribute "scenario=${_NR_CTX_SCENARIO}"
                   --custom-attribute "change_type=${_NR_CTX_CHANGE_TYPE}"
                   --custom-attribute "target_entities=${_NR_CTX_TARGET_ENTITIES}")
    fi

    if python3 "${repo_root}/utils/scripts/new_relic/send_change_tracking_marker.py" \
        --api-key "${NR_USER_API_KEY}" \
        --account-id "${NR_ACCOUNT_ID}" \
        --app-name "${NR_CHANGE_TRACKING_APP_NAME}" \
        --entity-domain APM \
        --category "${_nr_category}" \
        --type "${_nr_type}" \
        --version "${_NR_CTX_VERSION}" \
        --user "platform-automation" \
        --short-description "${_nr_short}" \
        --description "${_nr_desc}" \
        ${_nr_attrs[@]+"${_nr_attrs[@]}"}; then
        echo "[nr-scenario] Change tracking marker sent."
    else
        echo "[nr-scenario] WARNING: change tracking marker failed to send — demo continues."
    fi
}
