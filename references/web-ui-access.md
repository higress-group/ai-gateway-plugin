# AI Gateway Management - Web UI Access Guide

## Overview

The AI Gateway Management skill provides a web-based management interface that can be accessed via multiple methods.

## Access Methods

### Method 1: Domain-based Access (Default)

```
http://manager-local.hiclaw.io:8080
```

This method requires the `manager-local.hiclaw.io` domain to be configured in your DNS or hosts file.

### Method 2: Path-based Access (LAN/Internet) ⭐ Recommended

```
http://<your-server-ip>:8080/agm/
```

**Examples:**
- Local server: `http://192.168.1.100:8080/agm/`
- Cloud server: `http://47.100.200.30:8080/agm/`
- Localhost: `http://127.0.0.1:8080/agm/`

This method:
- ✅ Works without domain configuration
- ✅ Accessible from LAN or internet
- ✅ Automatically configured during skill installation
- ✅ Uses URL rewrite to serve the UI from `/agm/` path

## Authentication

Both access methods require **Basic Authentication**:

- **Username:** `admin` (or `HICLAW_ADMIN_USER` environment variable)
- **Password:** Set during HiClaw installation (or `HICLAW_ADMIN_PASSWORD` environment variable)

## How It Works

The installation script (`scripts/install.sh`) automatically configures Higress with:

1. **Service Source:** Points to nginx on port 18900 (serves the web UI)
2. **Route:** `/agm` path prefix with URL rewrite
3. **Authentication:** Basic auth plugin enabled

### Route Configuration

```json
{
  "name": "higress-manager-agm",
  "domains": [],
  "path": {
    "matchType": "PRE",
    "matchValue": "/agm"
  },
  "services": [{
    "name": "higress-manager.static",
    "port": 18900,
    "weight": 100
  }],
  "rewrite": {
    "enabled": true,
    "rewriteType": "PREFIX",
    "matchValue": "/agm",
    "replacement": "/"
  }
}
```

The `rewrite` configuration ensures that:
- Request to `/agm/` → serves `/index.html`
- Request to `/agm/js/app.js` → serves `/js/app.js`
- API requests to `/agm/v1/*` → proxies to Higress Console

## Installation

To install the skill and configure the web UI:

```bash
# As root inside the Manager container
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/install.sh
```

The installation script will:
1. Start the monitor API server on port 18080
2. Configure Higress routes for `/ni_status` API
3. Configure Higress routes for `/agm` web UI
4. Enable basic authentication
5. Display access URLs

## Troubleshooting

### Cannot access web UI

**Check if nginx is running:**
```bash
ps aux | grep nginx
```

**Check if port 18900 is listening:**
```bash
netstat -tlnp | grep 18900
```

**Check Higress route configuration:**
```bash
curl -s -b /tmp/higress-session-cookie http://127.0.0.1:8001/v1/routes/higress-manager-agm | jq
```

### Authentication fails

**Reset admin password:**
```bash
# Check environment variables
echo $HICLAW_ADMIN_USER
echo $HICLAW_ADMIN_PASSWORD

# Re-login to Higress Console
curl -X POST http://127.0.0.1:8001/session/login \
  -H 'Content-Type: application/json' \
  -c /tmp/higress-session-cookie \
  -d '{"username":"admin","password":"<your-password>"}'
```

### Route returns 404

**Verify service source exists:**
```bash
curl -s -b /tmp/higress-session-cookie http://127.0.0.1:8001/v1/service-sources | jq '.data[] | select(.name == "higress-manager.static")'
```

**Re-run installation script:**
```bash
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/install.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Client Browser                        │
│  Access: http://<server-ip>:8080/agm/                   │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Higress AI Gateway (port 8080)             │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Route: higress-manager-agm                        │  │
│  │ Path: /agm → Rewrite: /                           │  │
│  │ Auth: basic-auth (admin)                          │  │
│  └───────────────────┬──────────────────────────────┘  │
└─────────────────────┼──────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│              Nginx (port 18900)                          │
│  Root: /opt/hiclaw/agent/skills/ai-gateway-management  │
│  Serves: index.html, JS, CSS                            │
│  Proxies: /session/* → Higress Console                  │
│           /v1/* → Higress Console                        │
└─────────────────────────────────────────────────────────┘
```

## Security Considerations

### Production Deployment

For production use, consider:

1. **Enable HTTPS:**
   - Configure TLS certificate in Higress Console
   - Use `https://` instead of `http://`

2. **Restrict Access:**
   - Use firewall rules to limit IP ranges
   - Configure Higress consumer restrictions

3. **Strong Password:**
   - Use a strong admin password
   - Change default password immediately

4. **Monitor Logs:**
   - Check access logs regularly
   - Monitor for failed authentication attempts

## Related Files

- Web UI: `/opt/hiclaw/agent/skills/ai-gateway-management/web/index.html`
- Install script: `/opt/hiclaw/agent/skills/ai-gateway-management/scripts/install.sh`
- Nginx config: `/etc/nginx/conf.d/higress-manager.conf`
- Higress routes: Managed via Higress Console API

## Support

For issues or questions:
- Check troubleshooting section above
- Review installation logs
- Consult main documentation: `SKILL.md` and `README.md`
