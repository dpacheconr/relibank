#!/usr/bin/env bash
# Shadow IT Discovery Act 2 — Instrumentation Coverage demo trigger
#
# Usage:
#   ./trigger.sh start        # Add nr-apm-instrumented=true label to uninstrumented services
#   ./trigger.sh stop         # Remove nr-apm-instrumented label from the services start labelled
#   ./trigger.sh status       # Show current instrumentation coverage

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"

NAMESPACE="relibank"
UNINSTRUMENTED_SERVICES=("payment-gateway-service" "support-service" "risk-assessment-service")

usage() {
    echo "Usage: $0 {start|stop|status}"
    echo ""
    echo "  start    Add nr-apm-instrumented=true label to uninstrumented services"
    echo "  stop     Remove nr-apm-instrumented label from the services start labelled"
    echo "  status   Show current instrumentation coverage"
    exit 1
}

check_deps() {
    if ! command -v kubectl &>/dev/null; then
        echo "ERROR: kubectl is required but not installed." >&2
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "WARNING: jq not found — raw JSON will be printed." >&2
        JQ_CMD="cat"
    else
        JQ_CMD="jq ."
    fi
}

print_coverage() {
    local label="$1"
    echo ""
    echo "=== ${label} ==="

    local total
    local instrumented
    total=$(kubectl get deployment -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    instrumented=$(kubectl get deployment -n "${NAMESPACE}" \
        -o jsonpath='{range .items[?(@.spec.template.metadata.labels.nr-apm-instrumented=="true")]}{.metadata.name}{"\n"}{end}' | wc -l)

    echo "Total services: ${total}"
    echo "Instrumented: ${instrumented}"
    echo "Coverage: $(( instrumented * 100 / total ))%"

    echo ""
    echo "Instrumented services:"
    kubectl get deployment -n "${NAMESPACE}" \
        -o jsonpath='{range .items[?(@.spec.template.metadata.labels.nr-apm-instrumented=="true")]}{.metadata.name}{"\n"}{end}' | sort

    echo ""
    echo "Uninstrumented services:"
    kubectl get deployment -n "${NAMESPACE}" \
        -o jsonpath='{range .items[?(@.spec.template.metadata.labels.nr-apm-instrumented!="true")]}{.metadata.name}{"\n"}{end}' | sort
}

check_deps
ACTION="${1:-}"

case "${ACTION}" in
    start)
        nr_set_context "2" "Instrumentation Coverage" "CONFIG" \
            "nr-apm-instrumented=true label applied to 3 uninstrumented services (100% coverage reached via k8s-agents-operator)" "APM"
        nr_push_change_tracking

        echo "Adding nr-apm-instrumented=true label to uninstrumented services..."
        for service in "${UNINSTRUMENTED_SERVICES[@]}"; do
            echo "  Patching ${service}..."
            if kubectl patch deployment "${service}" -n "${NAMESPACE}" \
                -p '{"spec":{"template":{"metadata":{"labels":{"nr-apm-instrumented":"true"}}}}}' 2>/dev/null; then
                echo "    ✓ ${service} patched"
            else
                echo "    ⚠ ${service} not found or already patched"
            fi
        done

        echo ""
        echo "Waiting for rollouts to complete (up to 120 seconds)..."
        for service in "${UNINSTRUMENTED_SERVICES[@]}"; do
            kubectl rollout status deployment/"${service}" -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true
        done

        print_coverage "Coverage After Instrumentation"

        echo ""
        echo "Next steps:"
        echo "  1. Wait ~30-60 seconds for the k8s-agents-operator to inject the Python agent"
        echo "  2. Watch New Relic APM → Applications — new services should appear"
        echo "  3. Check the Catalog for 100% coverage"
        echo "  4. Run NRQL queries per service"
        echo ""
        echo "To revert: ./trigger.sh stop"
        ;;

    stop)
        nr_set_context "2" "Instrumentation Coverage Reset" "CONFIG" \
            "nr-apm-instrumented label removed from the 3 demo services" "APM"
        nr_push_change_tracking

        # Only the services start labelled: patching --all would remove the label from every
        # deployment in the namespace and roll the whole app (including DB-facing services).
        echo "Removing nr-apm-instrumented label from the services start instrumented..."
        for service in "${UNINSTRUMENTED_SERVICES[@]}"; do
            kubectl patch deployment "${service}" -n "${NAMESPACE}" \
                -p '{"spec":{"template":{"metadata":{"labels":{"nr-apm-instrumented":null}}}}}' 2>/dev/null || true
        done

        echo "Waiting for rollouts to complete (up to 120 seconds)..."
        for service in "${UNINSTRUMENTED_SERVICES[@]}"; do
            kubectl rollout status deployment/"${service}" -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true
        done

        print_coverage "Coverage After Reset"

        echo ""
        echo "Instrumentation removed. Services will drop out of APM within ~60 seconds."
        ;;

    status)
        print_coverage "Current Instrumentation Coverage"
        ;;

    *)
        usage
        ;;
esac
