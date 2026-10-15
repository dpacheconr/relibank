#!/usr/bin/env bash
# Noisy Neighbor scenario trigger: deterministic colocated contention (AKS adaptation)
set -euo pipefail

# shellcheck source=../lib/nr-scenario.sh
source "$(dirname "$0")/../lib/nr-scenario.sh"

NAMESPACE="relibank"
BASE_URL="${BASE_URL:-}"
NN_VICTIM_REQUEST="${NN_VICTIM_REQUEST:-50m}"
NN_VICTIM_LIMIT="${NN_VICTIM_LIMIT:-500m}"
NN_NEIGHBOR_REQUEST="${NN_NEIGHBOR_REQUEST:-900m}"

usage() {
  echo "Usage: $0 <start|stop|neighbor-start|neighbor-stop|burst|cap|uncap|status>"
  echo ""
  echo "  start    Full scenario, no manual steps: neighbor-start + non-blocking burst Job"
  echo "  stop     Full restore: delete burst Job + neighbor-stop"
  echo "  neighbor-start  Squeeze victim resources, patch pod affinity, deploy neighbor (1 pod, 30min)"
  echo "  neighbor-stop   Revert victims, remove batch-analytics, restore HPA"
  echo "  burst    Run burst load (250 users, 15 minutes) — requires BASE_URL env var"
  echo "  cap      Reduce HPA maxReplicas to 2 (simulate old scale limit)"
  echo "  uncap    Restore HPA maxReplicas to 5 (the fix)"
  echo "  status   Show current HPA and pod state"
  exit 1
}

# Helper: get bill-pay-service pod's node name
get_billpay_node() {
  kubectl get pod -n "$NAMESPACE" -l app=bill-pay-service -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo ""
}

# Helper: get node allocatable CPU in millicores
get_node_allocatable_cpu() {
  local node="$1"
  kubectl get node "$node" -o jsonpath='{.status.allocatable.cpu}' | sed 's/m$//' || echo "0"
}

# Helper: save current value as annotation on resource
save_annotation() {
  local kind="$1" resource="$2" key="$3" value="$4"
  kubectl patch "$kind" "$resource" -n "$NAMESPACE" --type merge -p "{\"metadata\":{\"annotations\":{\"$key\":\"$value\"}}}" >/dev/null 2>&1 || true
}

# Helper: get annotation value (fallback to empty string)
get_annotation() {
  local kind="$1" resource="$2" key="$3"
  kubectl get "$kind" "$resource" -n "$NAMESPACE" -o jsonpath="{.metadata.annotations.$key}" 2>/dev/null || echo ""
}

# Helper: clear annotation (escape forward slash in key)
clear_annotation() {
  local kind="$1" resource="$2" key="$3"
  local escaped_key=$(echo "$key" | sed 's|/|~1|g')
  kubectl patch "$kind" "$resource" -n "$NAMESPACE" --type json -p "[{\"op\":\"remove\",\"path\":\"/metadata/annotations/$escaped_key\"}]" >/dev/null 2>&1 || true
}

# Helper: ensure Chaos Mesh is installed (idempotent)
ensure_chaos_mesh() {
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

# Helper: resolve burst target (BASE_URL, else use relibank_base_url helper)
resolve_base_url() {
  if [[ -z "$BASE_URL" ]]; then
    BASE_URL=$(relibank_base_url)
    [[ -z "$BASE_URL" ]] && { echo "ERROR: BASE_URL not set and no ingress found"; exit 1; }
  fi
}

# Helper: create the burst load Job (250 users, 15 min) without waiting for it
create_burst_job() {
  resolve_base_url

  echo "Targeting: $BASE_URL"

  # Create ConfigMap from existing stress_loadgen file
  echo "Creating ConfigMap burst-locustfile from stress_loadgen..."
  kubectl create configmap burst-locustfile -n "$NAMESPACE" \
    --from-file="$(dirname "$0")/../stress_loadgen/bill_pay_service_load.py" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl delete job -n "$NAMESPACE" load-generator-burst --ignore-not-found=true

  # Create Job from manifest using stock locustio/locust image with ConfigMap-mounted load file
  kubectl apply -f - <<JOBDEF
apiVersion: batch/v1
kind: Job
metadata:
  name: load-generator-burst
  namespace: $NAMESPACE
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 1200
  template:
    metadata:
      labels:
        app: load-generator
    spec:
      restartPolicy: Never
      containers:
      - name: locust
        image: locustio/locust:2.29.1
        args:
        - -f
        - /mnt/locust/bill_pay_service_load.py
        - --host=$BASE_URL
        - --headless
        - --users=250
        - --spawn-rate=25
        - --run-time=15m
        - --only-summary
        volumeMounts:
        - name: locust-files
          mountPath: /mnt/locust
        resources:
          requests:
            memory: "256Mi"
            cpu: "500m"
          limits:
            memory: "512Mi"
            cpu: "1000m"
      volumes:
      - name: locust-files
        configMap:
          name: burst-locustfile
JOBDEF
}

[[ $# -lt 1 ]] && usage

case "$1" in
  neighbor-start)
    # Ensure Chaos Mesh is available (noisy-neighbor doesn't use it, but good to have)
    ensure_chaos_mesh

    # No NR change marker: the root cause must be discovered from telemetry, not read off the timeline
    echo "=== Resolving victim node placement ==="
    BILLPAY_NODE=$(get_billpay_node)
    [[ -z "$BILLPAY_NODE" ]] && { echo "ERROR: bill-pay-service pod not found"; exit 1; }
    echo "bill-pay-service is on node: $BILLPAY_NODE"

    # Allow NN_SPINNERS override; fall back to computed cores from node, or 1 with warning
    if [[ -n "${NN_SPINNERS:-}" ]]; then
      ALLOCATABLE_CORES="$NN_SPINNERS"
      echo "Using NN_SPINNERS=$ALLOCATABLE_CORES (override)"
    else
      ALLOCATABLE_CPU=$(get_node_allocatable_cpu "$BILLPAY_NODE")
      ALLOCATABLE_CORES=$(( (ALLOCATABLE_CPU + 999) / 1000 ))
      if [[ $ALLOCATABLE_CORES -lt 1 ]]; then
        ALLOCATABLE_CORES=1
        echo "WARNING: unable to read node CPU; using ALLOCATABLE_CORES=1" >&2
      fi
      echo "Node allocatable CPU: ${ALLOCATABLE_CPU}m (${ALLOCATABLE_CORES} cores)"
    fi

    echo ""
    echo "=== Squeezing victim resources (storing originals in annotations) ==="

    # bill-pay-service: read deployed values, save originals, apply squeeze + HPA lock
    echo "Patching bill-pay-service..."
    ORIG_BP_REQ=$(kubectl get deployment bill-pay-service -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
    ORIG_BP_LIM=$(kubectl get deployment bill-pay-service -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)
    [[ -z "$ORIG_BP_REQ" ]] && ORIG_BP_REQ="250m"
    [[ -z "$ORIG_BP_LIM" ]] && ORIG_BP_LIM="1000m"
    save_annotation deployment bill-pay-service "relibank/nn-orig-cpu-request" "$ORIG_BP_REQ"
    save_annotation deployment bill-pay-service "relibank/nn-orig-cpu-limit" "$ORIG_BP_LIM"

    kubectl patch deployment bill-pay-service -n "$NAMESPACE" --type strategic \
      -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"bill-pay-service\",\"resources\":{\"requests\":{\"cpu\":\"$NN_VICTIM_REQUEST\"},\"limits\":{\"cpu\":\"$NN_VICTIM_LIMIT\"}}}]}}}}"

    # transaction-service: read deployed values (second resources block overrides first), save per-container, apply squeeze + pod affinity
    echo "Patching transaction-service..."
    ORIG_TS_REQ=$(kubectl get deployment transaction-service -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="transaction-service")].resources.requests.cpu}' 2>/dev/null)
    ORIG_TS_LIM=$(kubectl get deployment transaction-service -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="transaction-service")].resources.limits.cpu}' 2>/dev/null)
    [[ -z "$ORIG_TS_REQ" ]] && ORIG_TS_REQ="500m"
    [[ -z "$ORIG_TS_LIM" ]] && ORIG_TS_LIM="2000m"
    save_annotation deployment transaction-service "relibank/nn-orig-cpu-request" "$ORIG_TS_REQ"
    save_annotation deployment transaction-service "relibank/nn-orig-cpu-limit" "$ORIG_TS_LIM"

    # Patch transaction-service: resources + pod affinity
    kubectl patch deployment transaction-service -n "$NAMESPACE" --type strategic \
      -p "{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"podAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":[{\"labelSelector\":{\"matchExpressions\":[{\"key\":\"app\",\"operator\":\"In\",\"values\":[\"bill-pay-service\"]}]},\"topologyKey\":\"kubernetes.io/hostname\"}]}},\"containers\":[{\"name\":\"transaction-service\",\"resources\":{\"requests\":{\"cpu\":\"$NN_VICTIM_REQUEST\"},\"limits\":{\"cpu\":\"$NN_VICTIM_LIMIT\"}}}]}}}}"

    # bill-pay HPA: read deployed values, save originals, lock to 1 replica
    echo "Locking bill-pay HPA to 1 replica..."
    ORIG_HPA_MIN=$(kubectl get hpa bill-pay-service -n "$NAMESPACE" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
    ORIG_HPA_MAX=$(kubectl get hpa bill-pay-service -n "$NAMESPACE" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
    [[ -z "$ORIG_HPA_MIN" ]] && ORIG_HPA_MIN="1"
    [[ -z "$ORIG_HPA_MAX" ]] && ORIG_HPA_MAX="5"
    save_annotation hpa bill-pay-service "relibank/nn-orig-hpa-min" "$ORIG_HPA_MIN"
    save_annotation hpa bill-pay-service "relibank/nn-orig-hpa-max" "$ORIG_HPA_MAX"

    kubectl patch hpa bill-pay-service -n "$NAMESPACE" --type merge \
      -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'

    echo ""
    echo "=== Waiting for victim rollouts ==="
    kubectl rollout status deployment/bill-pay-service -n "$NAMESPACE" --timeout=90s
    kubectl rollout status deployment/transaction-service -n "$NAMESPACE" --timeout=90s

    echo ""
    echo "=== Deploying batch-analytics neighbor (Deployment with pod affinity to bill-pay) ==="
    kubectl apply -k "$(dirname "$0")/../../k8s/overlays/noisy-neighbor"

    echo "=== Waiting for batch-analytics pod to schedule ==="
    for attempt in {1..30}; do
      NEIGHBOR_NODE=$(kubectl get pod -n "$NAMESPACE" -l app=batch-analytics -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
      if [[ -n "$NEIGHBOR_NODE" ]]; then
        echo "✓ batch-analytics scheduled on node: $NEIGHBOR_NODE"
        break
      fi
      if [[ $attempt -eq 30 ]]; then
        echo "ERROR: batch-analytics pod pending after 30s (Insufficient CPU?)"
        echo "Try reducing NN_NEIGHBOR_REQUEST or NN_VICTIM_REQUEST"
        exit 1
      fi
      sleep 1
    done

    echo ""
    echo "=== Setting neighbor dynamic parameters ==="
    # SPINNERS = allocatable cores
    kubectl set env deployment/batch-analytics -n "$NAMESPACE" SPINNERS="$ALLOCATABLE_CORES"

    # Neighbor request: use override or default 900m
    NEIGHBOR_REQ="${NN_NEIGHBOR_REQUEST:-900m}"
    kubectl set resources deployment/batch-analytics -n "$NAMESPACE" -c analytics-worker \
      --requests=cpu="$NEIGHBOR_REQ"

    echo "Neighbor SPINNERS=$ALLOCATABLE_CORES, CPU request=$NEIGHBOR_REQ"
    kubectl rollout status deployment/batch-analytics -n "$NAMESPACE" --timeout=90s

    echo ""
    echo "Neighbor placement:"
    kubectl get pods -n "$NAMESPACE" -o wide --no-headers \
      | awk '{print $7, $1}' | sort | grep -E 'batch-analytics|bill-pay|transaction'
    echo ""
    echo "CPU burns for 30 minutes. Investigate in NR: K8s 360 -> node -> pods by CPU."
    ;;

  neighbor-stop)
    echo "=== Removing batch-analytics Deployment ==="
    kubectl delete -k "$(dirname "$0")/../../k8s/overlays/noisy-neighbor" --ignore-not-found=true

    echo ""
    echo "=== Reverting victim resources (from annotations or base values) ==="

    # bill-pay-service: restore CPU (must use annotation; fallback is error)
    echo "Restoring bill-pay-service..."
    BP_REQ=$(get_annotation deployment bill-pay-service "relibank/nn-orig-cpu-request")
    BP_LIM=$(get_annotation deployment bill-pay-service "relibank/nn-orig-cpu-limit")
    if [[ -z "$BP_REQ" ]] || [[ -z "$BP_LIM" ]]; then
      echo "WARNING: Missing HPA annotations; using defaults (250m/1000m)"
      BP_REQ="${BP_REQ:-250m}"
      BP_LIM="${BP_LIM:-1000m}"
    fi
    kubectl patch deployment bill-pay-service -n "$NAMESPACE" --type strategic \
      -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"bill-pay-service\",\"resources\":{\"requests\":{\"cpu\":\"$BP_REQ\"},\"limits\":{\"cpu\":\"$BP_LIM\"}}}]}}}}"
    clear_annotation deployment bill-pay-service "relibank/nn-orig-cpu-request"
    clear_annotation deployment bill-pay-service "relibank/nn-orig-cpu-limit"

    # transaction-service: restore CPU and remove pod affinity (must use annotation; fallback is error)
    echo "Restoring transaction-service..."
    TS_REQ=$(get_annotation deployment transaction-service "relibank/nn-orig-cpu-request")
    TS_LIM=$(get_annotation deployment transaction-service "relibank/nn-orig-cpu-limit")
    if [[ -z "$TS_REQ" ]] || [[ -z "$TS_LIM" ]]; then
      echo "WARNING: Missing transaction-service annotations; using defaults (500m/2000m)"
      TS_REQ="${TS_REQ:-500m}"
      TS_LIM="${TS_LIM:-2000m}"
    fi
    kubectl patch deployment transaction-service -n "$NAMESPACE" --type strategic \
      -p "{\"spec\":{\"template\":{\"spec\":{\"affinity\":null,\"containers\":[{\"name\":\"transaction-service\",\"resources\":{\"requests\":{\"cpu\":\"$TS_REQ\"},\"limits\":{\"cpu\":\"$TS_LIM\"}}}]}}}}"
    clear_annotation deployment transaction-service "relibank/nn-orig-cpu-request"
    clear_annotation deployment transaction-service "relibank/nn-orig-cpu-limit"

    # bill-pay HPA: restore min/max (must use annotation; fallback is error)
    echo "Restoring bill-pay HPA..."
    HPA_MIN=$(get_annotation hpa bill-pay-service "relibank/nn-orig-hpa-min")
    HPA_MAX=$(get_annotation hpa bill-pay-service "relibank/nn-orig-hpa-max")
    if [[ -z "$HPA_MIN" ]] || [[ -z "$HPA_MAX" ]]; then
      echo "WARNING: Missing HPA annotations; using defaults (1/5)"
      HPA_MIN="${HPA_MIN:-1}"
      HPA_MAX="${HPA_MAX:-5}"
    fi
    kubectl patch hpa bill-pay-service -n "$NAMESPACE" --type merge \
      -p "{\"spec\":{\"minReplicas\":$HPA_MIN,\"maxReplicas\":$HPA_MAX}}"
    clear_annotation hpa bill-pay-service "relibank/nn-orig-hpa-min"
    clear_annotation hpa bill-pay-service "relibank/nn-orig-hpa-max"

    echo ""
    echo "=== Waiting for victim rollouts ==="
    kubectl rollout status deployment/bill-pay-service -n "$NAMESPACE" --timeout=90s
    kubectl rollout status deployment/transaction-service -n "$NAMESPACE" --timeout=90s
    echo "All systems restored to baseline."
    ;;

  start)
    # Fully automated: contention setup + non-blocking burst load (loop-friendly)
    "$0" neighbor-start
    echo ""
    echo "=== Starting burst load (250 users, 15 minutes) via in-cluster Job (not waiting) ==="
    create_burst_job
    echo "Burst running in background. Run '$0 stop' to restore everything."
    ;;

  stop)
    echo "=== Removing burst load Job ==="
    kubectl delete job -n "$NAMESPACE" load-generator-burst --ignore-not-found=true
    echo "=== Removing burst-locustfile ConfigMap ==="
    kubectl delete configmap -n "$NAMESPACE" burst-locustfile --ignore-not-found=true
    "$0" neighbor-stop
    ;;

  burst)
    echo "=== Starting burst load (250 users, 15 minutes) via in-cluster Job ==="
    create_burst_job

    echo ""
    echo "To check job status:"
    echo "  kubectl get job -n relibank load-generator-burst"
    echo "To view logs:"
    echo "  kubectl logs -n relibank -l job-name=load-generator-burst -f"
    echo "To clean up when complete:"
    echo "  kubectl delete job -n relibank load-generator-burst"
    ;;

  cap)
    nr_set_context "5" "Scale Burst" "INFRASTRUCTURE" \
        "HPA maxReplicas reduced to 2: bill-pay-service scale limit imposed" "K8S_CLUSTER"
    nr_push_change_tracking

    echo "=== Capping HPA maxReplicas to 2 (simulating old scale limit) ==="
    kubectl patch hpa bill-pay-service -n "$NAMESPACE" \
      --patch '{"spec":{"maxReplicas":2}}'
    echo "Done. HPA now capped at 2 replicas."
    ;;

  uncap)
    nr_set_context "5" "Scale Burst Fix" "INFRASTRUCTURE" \
        "HPA maxReplicas restored to 5: bill-pay-service scale limit lifted" "K8S_CLUSTER"
    nr_push_change_tracking

    echo "=== Restoring HPA maxReplicas to 5 (the fix) ==="
    kubectl patch hpa bill-pay-service -n "$NAMESPACE" \
      --patch '{"spec":{"maxReplicas":5}}'
    echo "Done. HPA restored to 5 replicas."
    echo ""
    echo "Watch scale-out:"
    echo "  kubectl get hpa bill-pay-service -n relibank -w"
    ;;

  status)
    echo "=== HPA Status ==="
    kubectl get hpa bill-pay-service -n "$NAMESPACE" \
      -o custom-columns=NAME:.metadata.name,CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas,MAX:.spec.maxReplicas,CPU:.status.currentMetrics[0].resource.current.averageUtilization

    echo ""
    echo "=== Bill-Pay Pods ==="
    kubectl get pods -n "$NAMESPACE" -l app=bill-pay-service \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CPU-REQ:.spec.containers[0].resources.requests.cpu

    echo ""
    echo "=== NR NRQL (K8s 360) ==="
    cat <<'NRQL'
SELECT
  max(cpuUsedCores / cpuLimitCores) * 100 AS 'CPU %',
  uniqueCount(podName) AS 'Pods'
FROM K8sContainerSample
WHERE namespaceName = 'relibank' AND podName LIKE 'bill-pay-service%'
SINCE 30 minutes ago TIMESERIES 1 minute
NRQL
    ;;

  *)
    usage
    ;;
esac
