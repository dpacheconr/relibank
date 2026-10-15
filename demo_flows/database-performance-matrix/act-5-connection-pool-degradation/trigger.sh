#!/usr/bin/env bash
# Act 5 — Connection Pool Degradation demo trigger
#
# Usage:
#   ./trigger.sh start        # Enable db-pool-stress (inject delay on pool-a)
#   ./trigger.sh stop         # Disable db-pool-stress (remove injection)
#   ./trigger.sh status       # Show current pool stress configuration
#   ./trigger.sh reset        # Reset all pool scenarios to defaults

set -euo pipefail

# shellcheck source=../../lib/nr-scenario.sh
source "$(dirname "$0")/../../lib/nr-scenario.sh"

SCENARIO_RUNNER_URL="${SCENARIO_RUNNER_URL:-http://scenario-runner-service:8000}"
BASE_URL="${SCENARIO_RUNNER_URL}/scenario-runner/api/ab-testing"

usage() {
    echo "Usage: $0 {start|stop|status|reset}"
    echo ""
    echo "  start    Enable db-pool-stress (inject 500ms delay on pool-a)"
    echo "  stop     Disable db-pool-stress (remove injection)"
    echo "  status   Show current pool stress configuration"
    echo "  reset    Reset all pool scenarios to defaults"
    echo ""
    echo "Environment:"
    echo "  SCENARIO_RUNNER_URL  Base URL for scenario runner (default: http://scenario-runner-service:8000)"
    exit 1
}

check_deps() {
    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl is required but not installed." >&2
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "WARNING: jq not found — raw JSON will be printed." >&2
        JQ_CMD="cat"
    else
        JQ_CMD="jq ."
    fi
}

print_status() {
    local label="$1"
    local response="$2"
    echo ""
    echo "=== ${label} ==="
    echo "${response}" | ${JQ_CMD}
    echo ""
}

check_deps
ACTION="${1:-}"

case "${ACTION}" in
    start)
        nr_set_context "1" "Pool Degradation" "CONFIG" \
            "db-pool-stress enabled: 500ms delay injected on pool-a (50/50 split)" "APM"
        nr_push_change_tracking

        echo "Enabling db-pool-stress (pool-a injection)..."
        echo "Target: ${BASE_URL}/db-pool-stress?enabled=true&delay_ms=500&affected_pool=pool-a"
        RESPONSE=$(curl -s -X POST \
            "${BASE_URL}/db-pool-stress?enabled=true&delay_ms=500&affected_pool=pool-a" \
            -H "Content-Type: application/json")
        print_status "Pool-A Stress ENABLED" "${RESPONSE}"

        echo "Verifying state..."
        STATUS=$(curl -s "${BASE_URL}/db-pool-stress")
        print_status "Current Pool Stress Config" "${STATUS}"

        echo "Next steps:"
        echo "  1. Wait ~10-15 seconds for delay to be applied"
        echo "  2. Watch NR APM accounts-service — segment by db.pool_id"
        echo "  3. Monitor db.pool_wait_time_ms for pool-a vs pool-b"
        echo "  4. Check DB 360 for connection pool exhaustion metrics"
        echo ""
        echo "To disable: ./trigger.sh stop"
        ;;

    stop)
        nr_set_context "1" "Pool Degradation Reset" "CONFIG" \
            "db-pool-stress disabled (pool injection removed)" "APM"
        nr_push_change_tracking

        echo "Disabling db-pool-stress..."
        echo "Target: ${BASE_URL}/db-pool-stress?enabled=false"
        RESPONSE=$(curl -s -X POST \
            "${BASE_URL}/db-pool-stress?enabled=false" \
            -H "Content-Type: application/json")
        print_status "Pool-A Stress DISABLED" "${RESPONSE}"

        echo "Verifying state..."
        STATUS=$(curl -s "${BASE_URL}/db-pool-stress")
        print_status "Current Pool Stress Config" "${STATUS}"

        echo "Recovery check:"
        echo "  - db.pool_wait_time_ms should normalize within ~10 seconds"
        echo "  - db.pool_exhausted should return to baseline"
        echo "  - APM latency should recover"
        ;;

    status)
        echo "Fetching current pool stress configuration..."
        RESPONSE=$(curl -s "${BASE_URL}/config")
        echo ""
        echo "=== DB Pool Stress Configuration ==="
        if command -v jq &>/dev/null; then
            echo "${RESPONSE}" | jq '.config | {db_pool_stress_enabled, db_pool_stress_delay_ms, db_pool_stress_affected_pool}'
        else
            echo "${RESPONSE}"
        fi
        echo ""
        ;;

    reset)
        echo "Resetting all pool scenarios to defaults..."
        RESPONSE=$(curl -s -X POST "${BASE_URL}/reset")
        print_status "Reset Response" "${RESPONSE}"
        ;;

    *)
        usage
        ;;
esac
