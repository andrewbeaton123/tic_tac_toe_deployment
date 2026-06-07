# Tic Tac Toe — Deployment Guide

This document describes the full Azure deployment for the Tic Tac Toe MLOps project. It covers the architecture, every infrastructure resource, why each exists, how to deploy step-by-step, and how to verify the system is healthy.

**Intended audience:** The project owner (you, later), other developers, or an LLM picking up this codebase cold.

---

## Repositories

| Repo | Purpose |
|------|---------|
| `tic_tac_toe_deployment` (this repo) | Terraform infrastructure — all Azure resources |
| `tic_tac_toe_model_serve` | FastAPI service that runs the Q-learning AI model |
| `tic_tac_toe_web_interface` | Flask web UI that humans interact with |

---

## Architecture Overview

```
Internet
    │ HTTPS
    ▼
┌─────────────────────────────────────────┐
│   Azure Front Door Standard             │
│   • WAF (rate limiting, custom rules)   │
│   • Global TLS termination              │
│   • Routes /* to web UI Container App   │
└─────────────────────────────────────────┘
    │ HTTP (internal)
    ▼
┌─────────────────────────────────────────────────────────────────┐
│   Azure Container Apps Environment  (VNet: 10.0.0.0/16)        │
│   Subnet: snet-aca  10.0.0.0/23                                 │
│                                                                 │
│   ┌─────────────────────────┐   ┌──────────────────────────┐   │
│   │  Web UI (Flask)         │──▶│  Model Serve (FastAPI)   │   │
│   │  port 8001              │   │  port 9100               │   │
│   │  external ingress       │   │  internal ingress only   │   │
│   │  (locked to AFD IPs)    │   │  (VNet-private FQDN)     │   │
│   └─────────────────────────┘   └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

Azure Container Registry (ACR)
    Docker images for both services are stored here

Monitoring
    Log Analytics Workspace  ← logs from Front Door + Container Apps
    Application Insights     ← request metrics, traces
    Metric Alerts            → email when error rate or restarts spike
```

### Why each component exists (DS analogy)

| Component | What it is | DS analogy |
|-----------|-----------|------------|
| Container Apps | Managed container runtime | Hosted inference cluster |
| Azure Container Registry | Docker image store | MLflow artifact store (for images) |
| Azure Front Door | Global entry point, TLS, WAF | API gateway / rate limiter before inference |
| Log Analytics Workspace | Central log database | Experiment tracking server (MLflow) |
| Application Insights | Metrics dashboard | wandb / Neptune |
| Metric Alerts | Automated notifications | Alerting when validation loss spikes |

---

## Security Model

### How the web UI is locked to Front Door only

The original Application Gateway setup used VNet-private Container App ingress — nothing outside the VNet could reach the backends. Azure Front Door Standard doesn't support Private Link (that requires Premium tier), so the web UI Container App technically has a public FQDN. Two layers close this gap:

**Layer 1 — Network: `AzureFrontDoor.Backend` service tag IP restriction**

The Container App ingress only accepts connections from IP ranges belonging to Azure Front Door. Azure maintains this list (the `AzureFrontDoor.Backend` service tag) automatically — you don't hardcode IPs. Any other source is dropped at the network edge before reaching the app.

> **Terraform provider limitation:** The `azurerm_container_app` provider validates `ip_address_range` as a CIDR and rejects service tag names, even though the underlying Azure API accepts them. This restriction must be applied via a single `az` CLI command after deployment (see Step 4 in Deployment Steps below).

**Layer 2 — Application: `X-Azure-FDID` header check**

Front Door injects a header `X-Azure-FDID: <your-profile-id>` on every forwarded request. The Flask app middleware rejects requests that don't carry this specific ID. This distinguishes *your* Front Door from other Azure customers whose traffic would also pass Layer 1 (because the service tag covers all Front Door deployments globally).

Together: Layer 1 = only Azure Front Door infrastructure can connect. Layer 2 = only your Front Door instance is accepted.

**Upgrade path:** Azure Front Door **Premium** ($330/month base) adds Private Link — Container Apps can revert to `external_enabled = false` and Front Door connects via a private endpoint inside the VNet, restoring true hard-boundary VNet isolation. Use Premium if this project ever handles sensitive user data.

### Model serve security

The model serve Container App has `external_enabled = false` — its FQDN is VNet-private. It is not reachable from the internet at all. Only the web UI (running in the same Container Apps Environment) can call it, via its internal FQDN.

The model serve API also requires the header `ocp-apim-subscription-key: <api-key>` on every request (validated via FastAPI dependency). The web UI passes this key from an environment secret.

---

## Terraform File Structure

The `azure/` directory is organised into one file per concern. Terraform merges all `.tf` files in a directory — this is purely for human readability.

```
azure/
├── providers.tf        # Terraform + provider version requirements
├── variables.tf        # All input variables (location, environment, secrets, etc.)
├── networking.tf       # Resource group, VNet, ACA subnet
├── acr.tf              # Azure Container Registry
├── container_apps.tf   # ACA environment + web UI + model serve apps
├── front_door.tf       # Front Door profile, endpoint, origin, route, WAF policy
├── monitoring.tf       # Log Analytics, App Insights, diagnostic settings, alerts
└── outputs.tf          # Useful values printed after terraform apply
```

### `networking.tf`

- `azurerm_resource_group.ttt` — resource group `rg-tictactoe-mlops-uk` in `uksouth`
- `azurerm_virtual_network.vnet` — VNet `vnet-tictactoe`, `10.0.0.0/16`
- `azurerm_subnet.c` — subnet `snet-aca`, `10.0.0.0/23`, delegated to `Microsoft.App/environments` (reserved exclusively for the Container Apps Environment)

### `acr.tf`

- `azurerm_container_registry.acr` — named `acrtictactoe<environment>` (globally unique, no hyphens). Basic SKU, `admin_enabled = true` so Container Apps can pull images using username/password credentials.

### `container_apps.tf`

- `azurerm_container_app_environment.env` — the shared cluster both apps run on. VNet-integrated via `infrastructure_subnet_id`. Logs shipped to Log Analytics.
- `azurerm_container_app.model_serve` — FastAPI AI service. Internal ingress only (`external_enabled = false`). Port 9100. Secrets: `API_KEY` (model serve auth key), ACR password.
- `azurerm_container_app.web_ui` — Flask web UI. External ingress (`external_enabled = true`), locked to `AzureFrontDoor.Backend` service tag. Port 8001. Env vars: `ENDPOINT_URL` (internal FQDN of model serve), `OCP_APIM_SUBSCRIPTION_KEY` (same value as model serve API key), `FLASK_SECRET_KEY`, `AZURE_FRONT_DOOR_ID`.

Both apps: `min_replicas = 1` to avoid cold-start latency on first request.

### `front_door.tf`

Azure Front Door uses the `azurerm_cdn_frontdoor_*` Terraform resource family — the "cdn" prefix is a legacy naming artefact from when Azure CDN and Front Door were merged. Don't be confused by it.

Resources in dependency order:
1. `azurerm_cdn_frontdoor_profile.fd` — the top-level Front Door resource. SKU: `Standard_AzureFrontDoor`.
2. `azurerm_cdn_frontdoor_endpoint.ep` — the public `*.azurefd.net` domain users hit.
3. `azurerm_cdn_frontdoor_origin_group.og` — load-balancing pool. Health probe: `HEAD /` every 30s.
4. `azurerm_cdn_frontdoor_origin.web_ui` — points to the web UI Container App FQDN.
5. `azurerm_cdn_frontdoor_rule_set.rs` — required by the route resource (even if empty).
6. `azurerm_cdn_frontdoor_route.route` — binds endpoint → origin group for `/*`. Forwards as HTTP (ACA handles TLS), HTTPS redirect enabled.
7. `azurerm_cdn_frontdoor_firewall_policy.waf` — WAF in Prevention mode (blocks, not just logs). Rate limit rule: block IPs exceeding 100 requests/minute.
8. `azurerm_cdn_frontdoor_security_policy.sp` — attaches WAF policy to the endpoint.

### `monitoring.tf`

1. `azurerm_log_analytics_workspace.law` — `PerGB2018` SKU (pay per GB ingested), 30-day retention.
2. `azurerm_application_insights.ai` — workspace-based (the modern approach; classic standalone is deprecated). Type: `web`.
3. `azurerm_monitor_diagnostic_setting` for ACA environment — ships `ContainerAppConsoleLogs` and `ContainerAppSystemLogs` to Log Analytics.
4. `azurerm_monitor_diagnostic_setting` for Front Door — ships `FrontDoorAccessLog` and `FrontDoorWebApplicationFirewallLog` to Log Analytics.
5. `azurerm_monitor_action_group.email_ag` — notification target for alerts: email to `var.alert_email`.
6. `azurerm_monitor_metric_alert` (5xx rate) — fires when Front Door `Percentage5XX` > 5% over 5 minutes. Severity: Warning.
7. `azurerm_monitor_metric_alert` (container restarts) — fires when ACA `RestartCount` > 3 in 5 minutes. Severity: Error (indicates a crash loop).

### `outputs.tf`

After `terraform apply`, these values are printed:

| Output | Description |
|--------|-------------|
| `resource_group_name` | Azure resource group name |
| `front_door_endpoint_url` | The public URL — give this to users |
| `acr_login_server` | ACR hostname for `docker push` |
| `web_ui_fqdn` | Internal ACA FQDN for the web UI (also Front Door origin) |
| `model_serve_fqdn` | Internal ACA FQDN for model serve (used in `ENDPOINT_URL`) |
| `application_insights_connection_string` | (sensitive) For SDK instrumentation |

---

## Input Variables

Defined in `variables.tf`. Values supplied via `terraform.tfvars` (gitignored) or `TF_VAR_*` environment variables.

| Variable | Type | Sensitive | Description |
|----------|------|-----------|-------------|
| `location` | string | no | Azure region. Default: `uksouth` |
| `environment` | string | no | `dev`, `test`, or `prod` |
| `tags` | map(string) | no | Tags applied to all resources |
| `model_serve_api_key` | string | **yes** | API key for model serve auth |
| `flask_secret_key` | string | **yes** | Flask session signing key |
| `model_serve_image_tag` | string | no | Docker image tag. Default: `latest` |
| `web_ui_image_tag` | string | no | Docker image tag. Default: `latest` |
| `alert_email` | string | no | Email for monitoring alert notifications |

Create `azure/terraform.tfvars` (already in `.gitignore`):

```hcl
environment         = "dev"
model_serve_api_key = "<generate a strong random key>"
flask_secret_key    = "<generate a long random string>"
alert_email         = "your-email@example.com"
```

---

## Prerequisites Before First Deployment

### 1. Fix the app code (two bugs that would break the deployment)

**Bug A — API header mismatch** (`tic_tac_toe_model_serve/tic_tac_toe_model_serve/auth.py`, line 4):

```python
# BEFORE (broken — web UI sends a different header name)
API_KEY_NAME = "tic-tac-key"

# AFTER
API_KEY_NAME = "ocp-apim-subscription-key"
```

Without this fix, every AI move returns 403 and the app silently falls back to random moves.

**Bug B — Missing health endpoint** (`tic_tac_toe_model_serve/app.py`):

```python
@app.get("/health")
async def health():
    return {"status": "ok"}
```

Without this, Front Door marks the origin as unhealthy and serves errors to all users.

**Bug C — Add Front Door ID middleware** (`tic_tac_toe_web_interface/tic_tac_toe_web_interface/app.py`):

```python
import os
FRONT_DOOR_ID = os.environ.get("AZURE_FRONT_DOOR_ID")

@app.before_request
def enforce_front_door():
    if FRONT_DOOR_ID:
        if request.headers.get("X-Azure-FDID") != FRONT_DOOR_ID:
            return "Forbidden", 403
```

This is Layer 2 of the security model. Push all three fixes to their repos before building Docker images.

### 2. Tools required

- `az` CLI — authenticated (`az login`)
- `terraform` >= 1.1.0
- `docker`

---

## Deployment Steps

### Step 1 — Bootstrap the Container Registry

ACR must exist before Docker images can be pushed. Images must exist before Container Apps can start. Break the cycle with a targeted first apply.

```bash
cd azure/
terraform init
terraform plan -target=azurerm_container_registry.acr -target=azurerm_resource_group.ttt
```

Review the plan output. If it looks correct:

```bash
terraform apply -target=azurerm_container_registry.acr -target=azurerm_resource_group.ttt
```

Note the `acr_login_server` value from the output (e.g. `acrtictactoedev.azurecr.io`).

### Step 2 — Build and push Docker images

```bash
# Authenticate Docker to your ACR
az acr login --name acrtictactoedev

# Model serve
cd /path/to/tic_tac_toe_model_serve
docker build -t acrtictactoedev.azurecr.io/model-serve:latest .
docker push acrtictactoedev.azurecr.io/model-serve:latest

# Web UI
cd /path/to/tic_tac_toe_web_interface
docker build -t acrtictactoedev.azurecr.io/web-ui:latest .
docker push acrtictactoedev.azurecr.io/web-ui:latest
```

### Step 3 — Deploy everything else

```bash
cd azure/
terraform plan    # review carefully before applying
terraform apply   # only run after reviewing the plan
```

### Step 4 — Apply the Front Door IP restriction (Layer 1 security)

The Terraform `azurerm_container_app` provider doesn't support service tag names in IP restrictions (it only accepts CIDR ranges), so this one step must be run via the `az` CLI after deployment:

```bash
az containerapp ingress access-restriction set \
  --name ca-web-ui \
  --resource-group rg-tictactoe-mlops-uk \
  --action Allow \
  --ip-address AzureFrontDoor.Backend \
  --rule-name AllowFrontDoor
```

This configures the Container App to only accept connections from Azure Front Door backend IPs. Azure maintains the IP list automatically — you never need to update it manually.

### Step 5 — Retrieve outputs

```bash
terraform output front_door_endpoint_url   # the URL to share with users
terraform output acr_login_server
terraform output web_ui_fqdn
terraform output model_serve_fqdn
```

---

## Verification Checklist

Run these after deployment to confirm the system is working end-to-end.

**1. Confirm Front Door IP restriction is active** (run after Step 4)
```bash
az containerapp ingress access-restriction list \
  --name ca-web-ui \
  --resource-group rg-tictactoe-mlops-uk
# Expect: entry with name "AllowFrontDoor", action "Allow", ipAddressRange "AzureFrontDoor.Backend"
```

**2. Front Door routing**
```bash
curl -I https://<front_door_endpoint_url>/
# Expect: HTTP 200 with X-Azure-Ref response header (confirms request went through AFD)
```

**3. Model serve reachable from web UI (internal only)**
```bash
az containerapp exec \
  --name ca-web-ui \
  --resource-group rg-tictactoe-mlops-uk \
  --command bash
# Inside the container shell:
curl -X POST http://<model_serve_fqdn>/next_move \
  -H "ocp-apim-subscription-key: <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"current_player": 2, "game_state": [0,0,0,0,0,0,0,0,0]}'
# Expect: {"move": <integer 0-8>}
```

**4. Front Door security check**
```bash
# Direct request to the Container App FQDN should be blocked
curl -I https://<web_ui_fqdn>/
# Expect: HTTP 403 (blocked by AzureFrontDoor.Backend IP restriction or FDID check)
```

**5. Logs flowing to Log Analytics**

In Azure Portal → Log Analytics Workspace → Logs:
```kql
ContainerAppConsoleLogs | take 10
```
Should show Flask/uvicorn startup lines.

**6. End-to-end game test**

Open `https://<front_door_endpoint_url>/` in a browser. Play a full game. If the AI responds with non-random moves, the header fix and auth chain are working correctly.

---

## Bugs Fixed From Original Terraform

| File | Bug | Fix Applied |
|------|-----|-------------|
| `main.tf` | Duplicate `provider "azurerm"` block | Deleted from main.tf; kept in providers.tf |
| `main.tf` | `azurerm_subnet.aca_subnet.id` — resource didn't exist | Replaced with `azurerm_subnet.c.id` |
| `main.tf` | Incomplete AppGW (empty blocks, invalid attributes, no public IP) | Entire AppGW resource deleted; replaced with Front Door |
| `outputs.tf` | `azurerm_resource_group.main` — resource didn't exist | Changed to `azurerm_resource_group.ttt` |
| `auth.py` (model serve) | `API_KEY_NAME = "tic-tac-key"` mismatched web UI header | Changed to `"ocp-apim-subscription-key"` |
| `app.py` (model serve) | No `/health` endpoint | Added `@app.get("/health")` |

---

## Cost Estimate (uksouth, dev environment)

| Resource | Approximate monthly cost |
|----------|--------------------------|
| Front Door Standard | ~$35 base + ~$0.01/GB transfer |
| Container Apps (Consumption, min 1 replica each) | ~$5–15 depending on usage |
| Azure Container Registry (Basic) | ~$5 |
| Log Analytics (PerGB2018, ~1 GB/month) | ~$2 |
| Application Insights | Included in Log Analytics cost |
| **Total estimate** | **~$50–60/month** |

To reduce costs in dev: set `min_replicas = 0` on both Container Apps (adds cold-start delay of ~10s on first request after idle).

---

## Upgrading to Production Security (Front Door Premium)

If this project ever handles sensitive user data, upgrade the Front Door tier:

1. Change `sku_name = "Standard_AzureFrontDoor"` → `"Premium_AzureFrontDoor"` in `front_door.tf`
2. Change the WAF policy `sku_name` to match
3. Add a `azurerm_cdn_frontdoor_origin.web_ui` private link configuration pointing to the Container App
4. Change web UI Container App ingress to `external_enabled = false`
5. Remove the `ip_security_restriction` blocks (no longer needed — connection is private)
6. Remove the `AZURE_FRONT_DOOR_ID` middleware (no longer needed)

This restores the hard VNet boundary that the original Application Gateway approach provided.
