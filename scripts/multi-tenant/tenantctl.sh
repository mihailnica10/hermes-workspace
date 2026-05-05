#!/usr/bin/env bash
# =============================================================================
# Hermes Workspace — Multi-Tenant Management Script
# =============================================================================
# Manage multiple isolated hermes-workspace + hermes-agent stacks on one host.
#
# Usage:
#   ./tenantctl.sh list                              # List all tenant stacks
#   ./tenantctl.sh create <tenant> [base_port]      # Create a new tenant
#   ./tenantctl.sh start <tenant>                   # Start a tenant
#   ./tenantctl.sh stop <tenant>                     # Stop a tenant
#   ./tenantctl.sh restart <tenant>                  # Restart a tenant
#   ./tenantctl.sh destroy <tenant>                  # Destroy a tenant (data loss!)
#   ./tenantctl.sh logs <tenant> [service]           # Tail logs (default: all)
#   ./tenantctl.sh status <tenant>                   # Show status
#   ./tenantctl.sh exec <tenant> <service> <cmd>     # Run command in container
#   ./tenantctl.sh ports <tenant>                    # Show port mapping
#   ./tenantctl.sh all <action>                      # Run action on all tenants
#
# Examples:
#   ./tenantctl.sh create acme 3010                  # Tenant "acme" on ports 3010/8652/9129
#   ./tenantctl.sh start acme                        # Start acme stack
#   ./tenantctl.sh logs acme hermes-workspace        # Tail workspace logs
#   ./tenantctl.sh all status                        # Status of all tenants
# =============================================================================

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
MULTI_COMPOSE="${MULTI_COMPOSE:-docker-compose.multi.yml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANTS_DIR="${TENANTS_DIR:-$SCRIPT_DIR/../.tenants}"
# Agent data lives here — one subdirectory per tenant.
# This is NOT the same as TENANTS_DIR which holds per-tenant .env configs.
HERMES_AGENTS_DIR="${HERMES_AGENTS_DIR:-$HOME/hermes-agents}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  sed -n '4,55p' "$0" | sed 's/^# //' | head -45
  echo ""
  echo "Environment variables:"
  echo "  COMPOSE_FILE=$COMPOSE_FILE"
  echo "  MULTI_COMPOSE=$MULTI_COMPOSE"
  echo "  TENANTS_DIR=$TENANTS_DIR"
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }
die() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1"; }

get_base_port() {
  local tenant="$1"
  local config="${TENANTS_DIR}/${tenant}/.env"
  if [[ -f "$config" ]]; then
    grep '^BASE_PORT=' "$config" | cut -d= -f2 | tr -d ' \r'
  else
    echo ""
  fi
}

get_tenant_port() {
  local base="$1"
  local offset="${2:-0}"
  echo $((base + offset))
}

# ─────────────────────────────────────────────────────────────────────────────
# Init
# ─────────────────────────────────────────────────────────────────────────────

init() {
  need_cmd docker
  need_cmd awk

  mkdir -p "$TENANTS_DIR"

  # Resolve compose files to absolute paths relative to the repo root
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  COMPOSE_FILE="${repo_root}/docker-compose.yml"
  MULTI_COMPOSE="${repo_root}/docker-compose.multi.yml"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tenant config management
# ─────────────────────────────────────────────────────────────────────────────

create_tenant_config() {
  local tenant="$1"
  local base_port="${2:-3000}"
  local tenant_dir="${TENANTS_DIR}/${tenant}"

  mkdir -p "$tenant_dir"

  # Generate tenant-specific .env
  cat > "${tenant_dir}/.env" <<EOF
# Tenant: ${tenant}
# Created: $(date -Iseconds)
TENANT_ID=${tenant}
BASE_PORT=${base_port}

# Provider keys — fill in your API keys below
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
GOOGLE_API_KEY=${GOOGLE_API_KEY:-}

# Authentication
HERMES_PASSWORD=${tenant}-$(openssl rand -hex 16)
API_SERVER_KEY=${tenant}-$(openssl rand -hex 16)
EOF

  log "Created tenant config in $tenant_dir"
  log "  Agent data: $HERMES_AGENTS_DIR/${tenant}/"
  log "  BASE_PORT=${base_port}"
  log "  Workspace:  http://localhost:${base_port}"
  log "  Gateway:    http://localhost:$((base_port + 5642))"
  log "  Dashboard:  http://localhost:$((base_port + 6119))"
  echo ""
  log "Edit ${tenant_dir}/.env to configure API keys and passwords."
  echo ""
  log "IMPORTANT: Create the agent data directory:"
  log "  mkdir -p $HERMES_AGENTS_DIR/${tenant}"
  log "  # Then copy or initialize your hermes-agent data there"
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker Compose wrapper
# ─────────────────────────────────────────────────────────────────────────────

compose() {
  local tenant="$1"
  shift
  local tenant_dir="${TENANTS_DIR}/${tenant}"

  if [[ ! -d "$tenant_dir" ]]; then
    die "Tenant not found: $tenant (did you run 'create' first?)"
  fi

  # Read all env vars from tenant .env and pass to docker compose
  # Run from repo root (not tenant dir) so ./data paths resolve correctly
  local base_port
  base_port=$(grep '^BASE_PORT=' "${tenant_dir}/.env" | cut -d= -f2 | tr -d ' \r')
  local gateway_port=$((base_port + 5642))
  local dashboard_port=$((base_port + 6119))

  # Build env command with all vars from tenant .env
  local env_args=""
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue
    # Extract var=value
    local var="${line%%=*}"
    local val="${line#*=}"
    # Remove leading/trailing whitespace from val
    val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Only add if not empty
    if [[ -n "$val" ]]; then
      env_args="${env_args} ${var}=${val}"
    fi
  done < "${tenant_dir}/.env"

  # Run docker compose from repo root
  # GATEWAY_PORT and DASHBOARD_PORT are computed from BASE_PORT.
  # HERMES_AGENTS_DIR tells the compose file where to mount agent data.
  eval env TENANT_ID="$tenant" \
    BASE_PORT="$base_port" \
    GATEWAY_PORT="$gateway_port" \
    DASHBOARD_PORT="$dashboard_port" \
    HERMES_AGENTS_DIR="$HERMES_AGENTS_DIR" \
    $env_args \
    docker compose \
      -f "$COMPOSE_FILE" \
      -f "$MULTI_COMPOSE" \
      --project-name "hermes-${tenant}" \
      "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

cmd_list() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│  Hermes Workspace — Active Tenants                                │"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""

  if [[ ! -d "$TENANTS_DIR" ]] || [[ -z "$(ls -A "$TENANTS_DIR" 2>/dev/null)" ]]; then
    echo "  No tenants found. Run '$0 create <name> [base_port]' to create one."
    echo ""
    return
  fi

  printf "%-12s %-10s %-20s %-15s %s\n" "TENANT" "BASE PORT" "WORKSPACE" "GATEWAY" "STATUS"
  printf "%-12s %-10s %-20s %-15s %s\n" "------" "---------" "---------" "-------" "------"

  for tenant_dir in "$TENANTS_DIR"/*; do
    [[ -d "$tenant_dir" ]] || continue
    tenant="$(basename "$tenant_dir")"

    base_port=$(get_base_port "$tenant" || echo "?")
    workspace_port="${base_port:-?}"
    gateway_port=$((base_port + 5642))
    dashboard_port=$((base_port + 6119))

    # Check if containers are running
    status="stopped"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^hermes-${tenant}-"; then
      status=$(docker compose \
        -f "$COMPOSE_FILE" \
        -f "$MULTI_COMPOSE" \
        -p "hermes-${tenant}" \
        ps --format json 2>/dev/null | \
        jq -r '.Service + ":" + .State' 2>/dev/null | \
        tr '\n' ' ' || echo "running")
    fi

    printf "%-12s %-10s %-20s %-15s %s\n" \
      "$tenant" "$base_port" "localhost:${workspace_port}" "localhost:${gateway_port}" "$status"
  done

  echo ""
}

cmd_create() {
  local tenant="$1"
  local base_port="${2:-}"

  [[ "$tenant" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Tenant must be alphanumeric (with - or _)"
  [[ ! -d "${TENANTS_DIR}/${tenant}" ]] || die "Tenant already exists: $tenant"

  # Auto-assign port if not specified
  if [[ -z "$base_port" ]]; then
    # Find next available port starting at 3010
    local used_ports=$(ls "$TENANTS_DIR" 2>/dev/null | while read t; do
      get_base_port "$t"
    done | sort -n)

    base_port=3010
    while echo "$used_ports" | grep -q "^${base_port}$"; do
      base_port=$((base_port + 10))
    done
    [[ $base_port -lt 9999 ]] || die "No available ports (tried up to 9999)"
  fi

  create_tenant_config "$tenant" "$base_port"
  log "Tenant '$tenant' created. Now run: $0 start $tenant"
}

cmd_start() {
  local tenant="$1"
  compose "$tenant" up -d
  log "Tenant '$tenant' started"
  cmd_ports "$tenant"
}

cmd_stop() {
  local tenant="$1"
  compose "$tenant" down
  log "Tenant '$tenant' stopped"
}

cmd_restart() {
  local tenant="$1"
  compose "$tenant" down
  sleep 1
  compose "$tenant" up -d
  log "Tenant '$tenant' restarted"
  cmd_ports "$tenant"
}

cmd_destroy() {
  local tenant="$1"
  read -p "This will DELETE ALL DATA for tenant '$tenant'. Are you sure? [y/N] " confirm
  [[ "${confirm:-N}" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

  compose "$tenant" down -v --remove-orphans
  rm -rf "${TENANTS_DIR}/${tenant}"
  rm -rf "${HERMES_AGENTS_DIR}/${tenant}"
  log "Tenant '$tenant' destroyed"
}

cmd_logs() {
  local tenant="$1"; shift
  local service="${1:-}"
  local svc_arg=()
  [[ -n "$service" ]] && svc_arg=("$service")

  compose "$tenant" logs -f "${svc_arg[@]}"
}

cmd_status() {
  local tenant="$1"
  compose "$tenant" ps
}

cmd_exec() {
  local tenant="$1"; shift
  local service="$1"; shift
  compose "$tenant" exec "$service" "$@"
}

cmd_ports() {
  local tenant="$1"
  local base_port="$(get_base_port "$tenant")"
  local ws=$((base_port))
  local gw=$((base_port + 5642))
  local dash=$((base_port + 6119))

  echo ""
  echo "Tenant: $tenant"
  echo "──────────────────────────────────────────"
  echo "  Workspace UI : http://localhost:${ws}"
  echo "  Gateway API  : http://localhost:${gw}"
  echo "  Dashboard    : http://localhost:${dash}"
  echo "──────────────────────────────────────────"
  echo ""
}

cmd_all() {
  local action="$1"; shift
  [[ -d "$TENANTS_DIR" ]] || { log "No tenants directory"; return; }

  for tenant_dir in "$TENANTS_DIR"/*; do
    [[ -d "$tenant_dir" ]] || continue
    tenant="$(basename "$tenant_dir")"
    echo ""
    echo "=== $tenant ==="
    case "$action" in
      status) compose "$tenant" ps ;;
      start)  compose "$tenant" up -d ;;
      stop)   compose "$tenant" down ;;
      *)      echo "Unknown action: $action" ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

init

ACTION="${1:-}"
case "$ACTION" in
  list)           cmd_list "$@";;
  create)         cmd_create "${2:-}" "${3:-}" ;;
  start)          cmd_start "${2:-}" ;;
  stop)           cmd_stop "${2:-}" ;;
  restart)        cmd_restart "${2:-}" ;;
  destroy)        cmd_destroy "${2:-}" ;;
  logs)           cmd_logs "${2:-}" "${3:-}" ;;
  status)         cmd_status "${2:-}" ;;
  exec)           cmd_exec "${2:-}" "${3:-}" "${@:4}" ;;
  ports)          cmd_ports "${2:-}" ;;
  all)            cmd_all "${2:-}" ;;
  -h|--help|help) usage; exit 0 ;;
  *)              usage; exit 1 ;;
esac
