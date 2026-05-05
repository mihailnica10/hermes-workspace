# Multi-Tenant Deployment Guide

This document describes how to run multiple isolated hermes-workspace + hermes-agent stacks on a single host using Docker.

## Architecture

Each tenant gets:
- **Isolated data directory**: `~/hermes-agents/<tenant>/` containing agent config, sessions, skills, and all state
- **Dedicated ports**: Each tenant uses unique host ports (avoiding conflicts)
- **Independent credentials**: Each tenant can have its own API keys and passwords
- **Private Docker network**: Each tenant's containers communicate over an isolated network

## Data Directory Structure

```
~/hermes-agents/
└── <tenant>/
    ├── config.yaml        # hermes-agent main config
    ├── .env               # hermes-agent environment variables
    ├── sessions/          # Agent chat sessions
    ├── skills/            # Installed skills
    ├── memories/          # Memory files
    ├── plans/             # Agent plans
    ├── cache/             # Model cache
    └── ... (other hermes-agent state)
```

## Quick Start with tenantctl.sh

```bash
# Create and start a new tenant "acme" (auto-assigns ports starting at 3010)
./scripts/multi-tenant/tenantctl.sh create acme
./scripts/multi-tenant/tenantctl.sh start acme

# List all tenants
./scripts/multi-tenant/tenantctl.sh list

# View logs
./scripts/multi-tenant/tenantctl.sh logs acme

# Stop / restart / destroy
./scripts/multi-tenant/tenantctl.sh stop acme
./scripts/multi-tenant/tenantctl.sh restart acme
./scripts/multi-tenant/tenantctl.sh destroy acme
```

## Port Allocation

| Service | Formula | Example (BASE_PORT=3010) |
|---------|---------|--------------------------|
| Workspace UI | BASE_PORT | 3010 |
| Gateway API | BASE_PORT + 5642 | 8652 |
| Dashboard | BASE_PORT + 6119 | 9129 |

**Formula derivation**:
- Gateway: `BASE_PORT + 5642` where 8642 is the gateway's container port
- Dashboard: `BASE_PORT + 6119` where 9119 is the dashboard's container port

## Environment Variables

Tenant configs live in `.tenants/<tenant>/.env`. Key variables:

| Variable | Description |
|----------|-------------|
| `TENANT_ID` | Unique tenant identifier |
| `BASE_PORT` | Starting port for workspace UI |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `HERMES_PASSWORD` | Workspace authentication password |
| `API_SERVER_KEY` | Gateway API authentication key |

## Agent Data Location

Agent data (config, sessions, skills, memory) is stored in `~/hermes-agents/<tenant>/`.

To migrate an existing agent or initialize a new one:
```bash
# Create the directory
mkdir -p ~/hermes-agents/<tenant>

# Copy existing agent data (if migrating)
cp -a /path/to/existing/agent/data/* ~/hermes-agents/<tenant>/

# Set ownership (if needed)
sudo chown -R $(id -u):$(id -g) ~/hermes-agents/<tenant>/
```

To completely remove a tenant and its data:
```bash
./scripts/multi-tenant/tenantctl.sh destroy acme
rm -rf ~/hermes-agents/acme
```

## How It Works

The `docker-compose.multi.yml` overlay modifies the base configuration:

1. **Dynamic port mapping**: Uses `${GATEWAY_PORT}` and `${DASHBOARD_PORT}` computed from `BASE_PORT`
2. **Tenant-specific volumes**: Data stored in `~/hermes-agents/<tenant>/`
3. **Environment isolation**: Each tenant's `.env` in `.tenants/<tenant>/.env` is loaded
4. **Container naming**: Each container gets a unique name with tenant suffix
5. **Docker DNS**: Container hostnames resolved automatically via Docker's embedded DNS

## Manual Setup (without tenantctl.sh)

```bash
# Create tenant directory and .env
mkdir -p ~/.hermes-agents/acme
cat > .tenants/acme/.env << 'EOF'
TENANT_ID=acme
BASE_PORT=3010
ANTHROPIC_API_KEY=sk-ant-...
HERMES_PASSWORD=your-secure-password
API_SERVER_KEY=another-secure-key
EOF

# Start tenant (from repo root)
HERMES_AGENTS_DIR=~/hermes-agents \
  TENANT_ID=acme BASE_PORT=3010 \
  GATEWAY_PORT=8652 DASHBOARD_PORT=9129 \
  docker compose -f docker-compose.yml -f docker-compose.multi.yml --project-name hermes-acme up -d
```

## Custom Agent Data Directory

By default, agent data lives in `~/hermes-agents/`. Override with `HERMES_AGENTS_DIR`:

```bash
HERMES_AGENTS_DIR=/data/hermes-agents ./scripts/multi-tenant/tenantctl.sh start acme
```

## Accessing Services

| Service | URL |
|---------|-----|
| Workspace UI | http://localhost:3010 |
| Gateway API | http://localhost:8652 |
| Dashboard (optional) | http://localhost:9129 |

## Known Limitations

- The dashboard service is not started by default in multi-tenant mode. Add `HERMES_DASHBOARD=1` to enable it.
- Each tenant requires a unique `BASE_PORT` to avoid port conflicts.
- hermes-agent must be run in Docker for proper multi-tenant isolation.

## Troubleshooting

### Port Conflicts
```bash
# Check what's using a port
sudo lsof -i :3010

# Assign a different port to the tenant
./scripts/multi-tenant/tenantctl.sh create acme 3030
```

### Workspace Can't Connect to Gateway
Ensure `API_SERVER_HOST=0.0.0.0` is set so the gateway listens on all interfaces.

### Container Exits Immediately
Check logs: `./scripts/multi-tenant/tenantctl.sh logs misumn hermes-agent`
