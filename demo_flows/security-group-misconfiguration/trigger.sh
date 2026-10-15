#!/usr/bin/env bash
# Security Group Misconfiguration (NSG wide-open database access)
#
# Simulates a security misconfiguration where the AKS node NSG is exposed to the internet
# via overly permissive rules (0.0.0.0/0 on ports 1433 [SQL Server] and 5432 [PostgreSQL]).
#
# Usage:
#   ./trigger.sh enable     # Add 0.0.0.0/0 ingress rules to node NSG (ports 1433, 5432)
#   ./trigger.sh cleanup    # Remove the overly permissive ingress rules
#   ./trigger.sh status     # Check current NSG rule status

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"


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

AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:?set AKS_CLUSTER_NAME}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-relibank-rg}"
NR_ACCOUNT_ID="${NR_ACCOUNT_ID:-}"

# NSG rule names and priorities for the misconfiguration
NSG_RULE_NAME_SQL="open-sql-server-internet"
NSG_RULE_NAME_PG="open-postgres-internet"
NSG_PRIORITY_BASE="200"

usage() {
  cat >&2 <<EOF
Usage: $0 <enable|cleanup|status>

  enable   — Add overly permissive ingress rules (0.0.0.0/0 on ports 1433, 5432) to node NSG
  cleanup  — Remove the 0.0.0.0/0 ingress rules from node NSG
  status   — Check current NSG rule status
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

# Helper: Get the node NSG for the AKS cluster
_get_node_nsg() {
  local cluster_name="$1"
  local resource_group="$2"

  # AKS node resource group follows pattern: MC_<resource_group>_<cluster_name>_<region>
  # Query for the first node NSG in the node resource group
  local node_rg=$(az group list --query "[?contains(name, 'MC_$resource_group') && contains(name, '$cluster_name')].name" -o tsv | head -1)

  if [[ -z "$node_rg" ]]; then
    echo "[ERROR] Could not find node resource group for cluster '$cluster_name'. Check your AKS_CLUSTER_NAME and AZURE_RESOURCE_GROUP."
    return 1
  fi

  local nsg_id=$(az network nsg list -g "$node_rg" --query "[0].id" -o tsv)

  if [[ -z "$nsg_id" ]] || [[ "$nsg_id" == "None" ]]; then
    echo "[ERROR] Could not find NSG in node resource group '$node_rg'."
    return 1
  fi

  echo "$nsg_id"
}

case "$1" in
  enable)
    echo "[security-group-misconfiguration] Enabling security group misconfiguration..."

    if ! command -v az &>/dev/null; then
      echo "[ERROR] Azure CLI (az) not available. Install it to run this scenario."
      exit 1
    fi

    # Get the node NSG
    NODE_NSG=$(
      _get_node_nsg "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" || {
        echo "[ERROR] Failed to identify node NSG."
        exit 1
      }
    )

    NSG_NAME="${NODE_NSG##*/}"
    NODE_RG="${NODE_NSG%/providers/Microsoft.Network/networkSecurityGroups/*}"
    NODE_RG="${NODE_RG##*/}"

    echo "[security-group-misconfiguration] Node NSG: $NSG_NAME (Resource Group: $NODE_RG)"
    echo ""

    # Add SQL Server rule (port 1433)
    echo "[security-group-misconfiguration] Adding 0.0.0.0/0 ingress rule for SQL Server (port 1433)..."
    az network nsg rule create \
      --resource-group "$NODE_RG" \
      --nsg-name "$NSG_NAME" \
      --name "$NSG_RULE_NAME_SQL" \
      --priority "$NSG_PRIORITY_BASE" \
      --direction Inbound \
      --protocol Tcp \
      --source-address-prefix "0.0.0.0/0" \
      --destination-port-ranges 1433 \
      --access Allow \
      2>/dev/null || {
      echo "[security-group-misconfiguration] ℹ SQL Server rule already exists or error occurred"
    }

    # Add PostgreSQL rule (port 5432)
    echo "[security-group-misconfiguration] Adding 0.0.0.0/0 ingress rule for PostgreSQL (port 5432)..."
    az network nsg rule create \
      --resource-group "$NODE_RG" \
      --nsg-name "$NSG_NAME" \
      --name "$NSG_RULE_NAME_PG" \
      --priority "$((NSG_PRIORITY_BASE + 1))" \
      --direction Inbound \
      --protocol Tcp \
      --source-address-prefix "0.0.0.0/0" \
      --destination-port-ranges 5432 \
      --access Allow \
      2>/dev/null || {
      echo "[security-group-misconfiguration] ℹ PostgreSQL rule already exists or error occurred"
    }

    echo "[security-group-misconfiguration] ✓ NSG rules added"
    ;;

  cleanup)
    echo "[security-group-misconfiguration] Cleaning up security group misconfiguration..."

    if ! command -v az &>/dev/null; then
      echo "[ERROR] Azure CLI (az) not available. Install it to run this scenario."
      exit 1
    fi

    # Get the node NSG
    NODE_NSG=$(
      _get_node_nsg "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" || {
        echo "[ERROR] Failed to identify node NSG."
        exit 1
      }
    )

    NSG_NAME="${NODE_NSG##*/}"
    NODE_RG="${NODE_NSG%/providers/Microsoft.Network/networkSecurityGroups/*}"
    NODE_RG="${NODE_RG##*/}"

    echo "[security-group-misconfiguration] Node NSG: $NSG_NAME (Resource Group: $NODE_RG)"
    echo ""

    # Remove SQL Server rule
    echo "[security-group-misconfiguration] Removing SQL Server ingress rule (port 1433)..."
    az network nsg rule delete \
      --resource-group "$NODE_RG" \
      --nsg-name "$NSG_NAME" \
      --name "$NSG_RULE_NAME_SQL" \
      2>/dev/null || {
      echo "[security-group-misconfiguration] ℹ SQL Server rule not found, nothing to remove"
    }

    # Remove PostgreSQL rule
    echo "[security-group-misconfiguration] Removing PostgreSQL ingress rule (port 5432)..."
    az network nsg rule delete \
      --resource-group "$NODE_RG" \
      --nsg-name "$NSG_NAME" \
      --name "$NSG_RULE_NAME_PG" \
      2>/dev/null || {
      echo "[security-group-misconfiguration] ℹ PostgreSQL rule not found, nothing to remove"
    }

    echo "[security-group-misconfiguration] ✓ NSG rules removed"
    ;;

  status)
    echo "[security-group-misconfiguration] Checking NSG rule status..."

    if ! command -v az &>/dev/null; then
      echo "[ERROR] Azure CLI (az) not available. Install it to run this scenario."
      exit 1
    fi

    # Get the node NSG
    NODE_NSG=$(
      _get_node_nsg "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" || {
        echo "[ERROR] Failed to identify node NSG."
        exit 1
      }
    )

    NSG_NAME="${NODE_NSG##*/}"
    NODE_RG="${NODE_NSG%/providers/Microsoft.Network/networkSecurityGroups/*}"
    NODE_RG="${NODE_RG##*/}"

    echo "[security-group-misconfiguration] Node NSG: $NSG_NAME"
    echo "[security-group-misconfiguration] Resource Group: $NODE_RG"
    echo ""

    # Check for SQL Server rule
    echo "[security-group-misconfiguration] Checking for SQL Server rule (port 1433)..."
    SQL_FOUND=$(az network nsg rule list -g "$NODE_RG" --nsg-name "$NSG_NAME" \
      --query "[?name=='$NSG_RULE_NAME_SQL'] | length(@)" -o tsv)

    if [[ "$SQL_FOUND" -gt 0 ]]; then
      echo "[security-group-misconfiguration] ⚠️  EXPOSED: SQL Server (port 1433) rule found"
    else
      echo "[security-group-misconfiguration] ✓ SECURE: No SQL Server rule on port 1433"
    fi

    # Check for PostgreSQL rule
    echo "[security-group-misconfiguration] Checking for PostgreSQL rule (port 5432)..."
    PG_FOUND=$(az network nsg rule list -g "$NODE_RG" --nsg-name "$NSG_NAME" \
      --query "[?name=='$NSG_RULE_NAME_PG'] | length(@)" -o tsv)

    if [[ "$PG_FOUND" -gt 0 ]]; then
      echo "[security-group-misconfiguration] ⚠️  EXPOSED: PostgreSQL (port 5432) rule found"
    else
      echo "[security-group-misconfiguration] ✓ SECURE: No PostgreSQL rule on port 5432"
    fi

    echo ""
    echo "[security-group-misconfiguration] All NSG rules:"
    az network nsg rule list -g "$NODE_RG" --nsg-name "$NSG_NAME" \
      --query "[].{Name:name,Priority:priority,Direction:direction,Protocol:protocol,SourcePrefix:sourceAddressPrefix,DestinationPorts:destinationPortRanges,Access:access}" \
      --output table
    ;;

  *)
    usage
    ;;
esac

exit 0
