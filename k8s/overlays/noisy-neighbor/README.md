# Noisy Neighbor Overlay

This overlay contains the batch-analytics Deployment for the Noisy Neighbor scenario.

**Important:** This overlay is deployed imperatively via `kubectl apply -k` inside trigger.sh, not as part of the standard deployment.

- `batch-analytics-deployment.yaml` - The offender Deployment with pod affinity to bill-pay-service
- `kustomization.yaml` - Kustomize configuration

See `demo_flows/noisy-neighbor/` for the complete scenario including trigger.sh and load testing scripts.
