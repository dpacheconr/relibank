# auto-attach Overlay

This overlay enables runtime APM auto-instrumentation for Python services via the New Relic k8s-agents-operator. It extends the `azure-prod` base overlay and adds:

- **Service patches**: Strategic merge patches on 7 deployments (accounts, auth, bill-pay, notifications, scheduler, support, transaction) that inject the `instrumentation.newrelic.com/inject-python: "true"` annotation and the `nr-apm-instrumented: "true"` label so the operator auto-injects the Python agent at runtime.
- **NEW_RELIC_APP_NAME env vars**: Each service gets its own app name for APM entity naming in New Relic.
- **Team labels**: Added to each service pod for eBPF entity tag discovery and NR Teams ownership assignment.
- **risk-assessment-service excluded**: Intentionally left uninstrumented for the Shadow IT Discovery demo — only visible via eBPF, not APM.

## Bootstrap Prerequisites

The k8s-agents-operator must be installed on the cluster before applying this overlay. The operator is installed automatically during AKS cluster setup via Terraform as part of `terraform/aks/relibank-<color>/` deployment. See `terraform/aks/newrelic/nr_infra_agent.tf` for the operator and nri-bundle Helm releases.

The Terraform configuration:

- Installs nri-bundle (infrastructure, eBPF, logging, Prometheus)
- Installs k8s-agents-operator (runtime APM auto-instrumentation)

The k8s-agents-operator Helm chart automatically creates the `newrelic-key-secret` Secret in the `newrelic` namespace with the license key. This secret is used by the Instrumentation CR to inject the Python agent into instrumented pods.

## Instrumentation CR

The `newrelic-instrumentation.yaml` CR defines how the operator injects the Python agent. It is applied separately (not via this overlay's kustomization.yaml) by the bootstrap script, after the operator and its CRD are installed.

```bash
kubectl apply -f k8s/overlays/auto-attach/newrelic-instrumentation.yaml
```

This separation ensures the overlay kustomization itself does not break if the CRD is not yet available on a fresh cluster.

## Usage

```bash
# On AKS after the operator is installed:
kubectl apply -k k8s/overlays/auto-attach
```

## Database Init

