# VEXA-CPU GCP Swarm Deployment

This directory contains everything needed to deploy VEXA-CPU to Google Cloud Platform using Docker Swarm.

## Quick Start

1. **Setup Environment**
   ```bash
   make env-setup
   # Edit .env.gcp with your actual GCP values
   make validate-env
   ```

2. **Setup GCP Infrastructure**
   ```bash
   make gcp-prerequisites  # Shows what you need to create manually
   ```

3. **Deploy**
   ```bash
   make stack-deploy  # Full deployment (builds images + deploys)
   # OR
   make quick-deploy  # Deploy without rebuilding images
   ```

4. **Monitor**
   ```bash
   make status        # Overall status
   make stack-ps      # Task status
   make stack-logs    # View logs
   ```

## Complete Workflow

### 1. Environment Setup
```bash
# Copy template and edit with your values
make env-setup
# Edit .env.gcp file with your actual:
# - GCP_PROJECT_ID
# - DB_HOST (Cloud SQL private IP)
# - REDIS_HOST (Memorystore private IP)
# - TRAEFIK_HOST (your domain)
# - DB_PASSWORD, ADMIN_API_TOKEN (secure values)

# Validate configuration
make validate-env
```

### 2. GCP Infrastructure (Manual Setup Required)
```bash
# See what needs to be created
make gcp-prerequisites

# You need to manually create:
# - GCP Project with billing enabled
# - Artifact Registry repository
# - Cloud SQL PostgreSQL instance
# - Memorystore Redis instance
# - Compute Engine VM for Swarm manager
# - Firewall rules for Swarm and Traefik
```

### 3. Deployment Options

**Full Deployment (builds + deploys):**
```bash
make stack-deploy
```

**Quick Deployment (config changes only):**
```bash
make quick-deploy
```

**Individual Steps:**
```bash
make images-auth              # Configure Docker auth
make images-build-push-all    # Build and push all images
make swarm-init              # Initialize Swarm on manager VM
make swarm-config-traefik    # Upload Traefik config
```

### 4. Management

**Status and Monitoring:**
```bash
make status                  # Complete status overview
make stack-ps               # Stack task status
make stack-logs             # All service logs
make stack-logs SERVICE_NAME=bot-manager  # Specific service logs
make show-config            # Current configuration
```

**Updates:**
```bash
# After code changes
make stack-deploy           # Rebuild images and redeploy

# After config-only changes
make quick-deploy          # Deploy without rebuilding
```

**Cleanup:**
```bash
make stack-rm              # Remove stack
make swarm-leave           # Leave swarm
make clean                 # Both of the above
```

## Architecture

- **Swarm Manager**: Single-node Swarm on GCP Compute Engine
- **Images**: Stored in GCP Artifact Registry
- **Database**: External Cloud SQL PostgreSQL
- **Cache**: External Memorystore Redis
- **Ingress**: Traefik reverse proxy
- **Services**: 
  - `api-gateway`: Main API entry point
  - `admin-api`: Admin interface
  - `bot-manager`: Manages bot instances
  - `whisperlive-cpu`: CPU-based speech recognition
  - `transcription-collector`: Processes transcriptions

## Environment Variables

All configuration is managed through `.env.gcp`. Key variables:

- `GCP_PROJECT_ID`: Your GCP project
- `GCP_REGION`, `GCP_ZONE`: Deployment location
- `DB_HOST`, `REDIS_HOST`: External service IPs
- `TRAEFIK_HOST`: Your domain name
- `LANGUAGE_DETECTION_SEGMENTS`, `VAD_FILTER_THRESHOLD`: Whisper settings

## Files

- `Makefile`: Complete deployment automation
- `env-example.gcp`: Environment template
- `.env.gcp`: Your actual configuration (created from template)
- `docker-compose.gcp-cpu.yml`: Swarm stack definition
- `traefik.toml`: Traefik configuration
- `services/*/Dockerfile*`: Service images

## Troubleshooting

**Validation Errors:**
```bash
make validate-env  # Check configuration
make show-config   # View current values
```

**Deployment Issues:**
```bash
make status        # Overall status
make stack-logs    # Check service logs
```

**Image Issues:**
```bash
make images-auth   # Re-authenticate with registry
```

**Swarm Issues:**
```bash
# SSH to manager and check manually
gcloud compute ssh vexa-manager-1 --zone=us-central1-a
sudo docker node ls
sudo docker service ls
```

## Security Notes

- Use Docker Secrets for sensitive values in production
- Secure Traefik dashboard access
- Use private networks for all GCP resources
- Regularly rotate API tokens and passwords 