# Phase 5: Deployment & Monitoring

Goal: Deploy the platform on a cloud VM with reliability, monitoring, and minimal cost.

Duration: 1 week

Implementation Details

1. VM Setup

Provider: Hetzner CX41 (4 vCPU, 16 GB RAM, 160 GB SSD, €10.59/month)
OS: Ubuntu 22.04 LTS
Software: Docker Engine, Docker Compose, Caddy (reverse proxy).

Provisioning via shell script:

```bash
# install-docker.sh + docker-compose.yml
```

2. Application Deployment

docker-compose.yml:

```yaml
version: '3.8'
services:
  api:
    build: ./api
    ports:
      - '3000:3000'
    environment:
      - ENCRYPTION_KEY=${ENCRYPTION_KEY}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - user_data:/user-home
    restart: unless-stopped
  frontend:
    build: ./frontend
    ports:
      - '8080:80'
    restart: unless-stopped
volumes:
  user_data:
```

3. Reverse Proxy & TLS

Caddyfile:

```
agent.example.com {
    reverse_proxy frontend:8080
    handle /api/* {
        reverse_proxy api:3000
    }
}
```

TLS is automatic via Let’s Encrypt.

4. Monitoring & Logging

· Container logs: Docker json-file driver with log rotation.
· API server logs: stdout, captured by Docker.
· Health check: /api/health endpoint that checks Docker connectivity.
· Uptime monitoring: UptimeRobot or Healthchecks.io (free tier).

5. Backup Strategy

Nightly script to back up user credential volume:

```bash
docker run --rm -v user_data:/data alpine tar czf /backup/user-home.tar.gz -C /data .
```

Copy off-server or use Hetzner Volume snapshots (€0.01/GB/month).

6. Cost Analysis

Item Monthly Cost
Hetzner CX41 €10.59
Backup snapshots (50 GB) ~€0.50
Domain name ~€1.00
Total ~€12.09

No API credits used. Unlimited sessions.

7. Constraints

· Single VM = single point of failure; acceptable for personal tool.
· Disk space: prune old workspace volumes if needed.
· Optional: IP whitelist or VPN for extra security.

Rejected Alternatives

· Serverless (AWS Fargate): More expensive, complex networking.
· Kubernetes (k3s): Overkill, higher resource overhead.

Deliverables

· Deployed platform accessible via HTTPS.
· Basic monitoring and alerting.
· Backup script.
· Maintenance runbook.
