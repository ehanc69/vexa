# Docker Swarm Cheat Sheet (VEXA-CPU Project Specific)

This sheet provides a quick reference for Docker Swarm commands relevant to the `vexa-cpu` project, using `vexa_stack` as the primary stack name, primarily for a **single-host deployment on node `bbb`**.

## I. Single-Host Swarm Setup & Deployment on `bbb` (Your Current Goal)

This section outlines the exact commands to get your `vexa_stack` running on your single machine (`bbb`), which will act as both manager and worker.

**Pre-requisites:**
*   You are in the `/home/dima/prod/vexa-cpu` directory in your terminal.
*   All custom service images have been built and tagged (e.g., `localhost:5000/vexa-admin-api:latest`).

**Step 1: Ensure Local Docker Registry is Running**
```bash
# Check if already running
docker ps --filter name=local-registry

# If not running, start it:
docker run -d -p 5000:5000 --restart=always --name local-registry registry:2
```

**Step 2: Push All VEXA Service Images to Local Registry**
*   This is a **CRUCIAL** step. Repeat for each service defined in `docker-compose.yml` that uses a `localhost:5000` image.
*   The `BOT_IMAGE_NAME` (e.g., `localhost:5000/vexa-bot:dev`) used by `bot-manager` also needs to be built and pushed.
*   **Run these commands from your `/home/dima/prod/vexa-cpu` directory.**
*   **Example for `bot-manager`:**
    ```bash
    (cd services/bot-manager && docker build -t localhost:5000/vexa-bot-manager:latest . && docker push localhost:5000/vexa-bot-manager:latest)
    ```
*   **Adapt and run for all your services:**
    *   `vexa-admin-api`: `(cd services/admin-api && docker build -t localhost:5000/vexa-admin-api:latest . && docker push localhost:5000/vexa-admin-api:latest)`
    *   `vexa-api-gateway`: `(cd services/api-gateway && docker build -t localhost:5000/vexa-api-gateway:latest . && docker push localhost:5000/vexa-api-gateway:latest)`
    *   `vexa-transcription-collector`: `(cd services/transcription-collector && docker build -t localhost:5000/vexa-transcription-collector:latest . && docker push localhost:5000/vexa-transcription-collector:latest)`
    *   `vexa-whisperlive-cpu`: `(cd services/WhisperLive && docker build -f Dockerfile.cpu -t localhost:5000/vexa-whisperlive-cpu:latest . && docker push localhost:5000/vexa-whisperlive-cpu:latest)`
    *   `vexa-whisperlive-gpu`: `(cd services/WhisperLive && docker build -f Dockerfile.project -t localhost:5000/vexa-whisperlive-gpu:latest . && docker push localhost:5000/vexa-whisperlive-gpu:latest)`
    *   `vexa-bot` (using `dev` tag as per your compose file): `(cd services/vexa-bot && docker build -t localhost:5000/vexa-bot:dev . && docker push localhost:5000/vexa-bot:dev)`
    *   *(Adjust Dockerfile names/paths if they differ for some services, e.g., if Dockerfile is in a sub-directory of `services/WhisperLive` or named differently)*
*   **Alternatively, if your `Makefile` (in `/home/dima/prod/vexa-cpu`) has targets for this, use them:**
    ```bash
    # make build-all-images push-all-images # (Replace with actual Makefile targets)
    ```

**Step 3: Initialize Docker Swarm on `bbb`**
*   Run these commands from `/home/dima/prod/vexa-cpu` or any directory.
```bash
# Check current Swarm status
docker info | grep Swarm

# If "Swarm: inactive", initialize it:
docker swarm init
```
*   For a single node, `--advertise-addr` is usually not needed.
*   Your node `bbb` is now a Swarm Manager (and will also run tasks as a worker).

**Step 4: Deploy the `vexa_stack`**
*   Ensure you are in `/home/dima/prod/vexa-cpu`.
```bash
docker stack deploy -c docker-compose.yml vexa_stack --with-registry-auth
```

**Step 5: Monitor Stack Deployment & Service Status**
*   Run these commands from `/home/dima/prod/vexa-cpu` or any directory.
```bash
# See overview of tasks starting up
docker stack ps vexa_stack --no-trunc

# List services and their replica status (e.g., 1/1)
docker stack services vexa_stack

# If any service shows 0/1 replicas or errors in 'docker stack ps':
# Check its logs, e.g., for admin-api:
docker service logs vexa_stack_admin-api --tail 100 --since 5m
```

## II. Routine VEXA Swarm Operations (on `bbb`)

*(Commands below can generally be run from any directory once Swarm is active)*

**Check Stack Status:**
```bash
docker stack ls
docker stack services vexa_stack
docker stack ps vexa_stack
```

**View Logs for a Specific Service (e.g., `bot-manager`):**
```bash
docker service logs vexa_stack_bot-manager -f --tail 100
```

**View Logs for dynamically created `vexa-bot-svc-...` services:**
```bash
# First, find the exact service name:
docker service ls --filter name=vexa-bot-svc
# Then, view logs for a specific one:
docker service logs <name-of-vexa-bot-service> -f --tail 50
```

**Update a Service After Pushing a New Image Version (e.g., `bot-manager`):**
```bash
# Re-build and re-push the image first (see Step 2 above, from /home/dima/prod/vexa-cpu)
# Then, force Swarm to update the service to use the new image (if :latest tag was used)
docker service update --force vexa_stack_bot-manager
# Or, if you used a new tag (e.g., :v1.1):
# docker service update --image localhost:5000/vexa-bot-manager:v1.1 vexa_stack_bot-manager
```

**Redeploy Entire Stack (e.g., after `docker-compose.yml` changes or to refresh all :latest images):**
*   Ensure you are in `/home/dima/prod/vexa-cpu`.
```bash
# Re-push any images that changed first!
docker stack deploy -c docker-compose.yml vexa_stack --with-registry-auth
```

## III. GPU Configuration for `whisperlive` (Single Host `bbb`)

If `vexa_stack_whisperlive` (GPU version) is pending due to "insufficient resources":

**1. Verify Hardware & NVIDIA Drivers on `bbb`:**
```bash
lspci | grep -i nvidia
# Ensure you see your NVIDIA GPU listed.
# Check NVIDIA driver version (e.g., nvidia-smi)
```

**2. Install/Verify NVIDIA Container Toolkit on `bbb`:**
*   This allows Docker to use NVIDIA GPUs. Follow official NVIDIA instructions.

**3. Configure Docker Daemon on `bbb` to Expose GPU as Swarm Resource:**
*   Edit `/etc/docker/daemon.json` (create if it doesn't exist, use `sudo`):
    ```json
    {
      "runtimes": {
        "nvidia": {
          "path": "nvidia-container-runtime",
          "runtimeArgs": []
        }
      },
      "node-generic-resources": [
        "NVIDIA-GPU=gpu1" 
      ]
    }
    ```
    *   Adjust `NVIDIA-GPU=gpu1` if your GPU has a different name or you have multiple. The `kind` used here (`NVIDIA-GPU`) must match your `docker-compose.yml` `discrete_resource_spec.kind`.

**4. Restart Docker Daemon on `bbb`:**
```bash
sudo systemctl restart docker
```

**5. Verify Node `bbb` Advertises GPU Resource:**
```bash
# Re-initialize swarm if it was torn down. If already active, this step might not be needed or could be `docker node inspect self`
docker node inspect bbb -P 
# Look for: "GenericResources": [ { "NamedResourceSpec": { "Kind": "NVIDIA-GPU", "Value": "gpu1" } } ]
```
*   If Swarm was previously active, and you just updated `daemon.json` and restarted docker, the node *should* update its advertised resources in the Swarm. If not, you might need to `docker node update --label-add ...` (though this is for labels, generic resources are different) or, in extreme cases, re-init Swarm if it's a fresh setup.

**6. Ensure `docker-compose.yml` for `whisperlive` Matches:**
*   The `deploy.resources.reservations.generic_resources.discrete_resource_spec.kind` should be `NVIDIA-GPU` (or whatever you used in `daemon.json`).

**7. Redeploy Stack or Update Service:**
*   Ensure you are in `/home/dima/prod/vexa-cpu`.
```bash
docker stack deploy -c docker-compose.yml vexa_stack --with-registry-auth
# OR
# docker service update --force vexa_stack_whisperlive
```

## IV. Taking Down the Swarm on `bbb` (Single Host)

*(Commands below can generally be run from any directory)*

**Step 1: Remove the `vexa_stack`**
```bash
docker stack rm vexa_stack
```
*   Wait for services/networks to be removed. Check with `docker service ls` and `docker network ls`.

**Step 2: Leave Swarm Mode on `bbb`**
```bash
docker swarm leave --force
```
*   `--force` is needed as `bbb` is the manager.

**Step 3: Verify Swarm is Inactive**
```bash
docker info | grep Swarm 
# Expected: Swarm: inactive
docker node ls
# Expected: Error response from daemon: This node is not a swarm manager...
```

**Step 4: (Optional) Stop and Remove Local Registry**
```bash
# docker stop local-registry
# docker rm local-registry
```

## V. General Swarm Concepts & Multi-Node (Beyond Single-Host `bbb`)

**(This section is more for future reference if you expand beyond a single node)**

*   **Nodes:** Machines in the Swarm.
*   **Manager Nodes:** Control plane, make scheduling decisions. Your `bbb` is one.
*   **Worker Nodes:** Run tasks as directed by managers. `bbb` also acts as a worker.
*   **Adding Workers:** `docker swarm join --token <WORKER-TOKEN> <MANAGER-IP>:<PORT>`
*   **Adding Managers:** `docker swarm join --token <MANAGER-TOKEN> <MANAGER-IP>:<PORT>`
*   **Overlay Networks (`vexa_stack_vexa_default`, `vexa_stack_whispernet`):** Allow services to communicate across all nodes in the Swarm.
*   **Host-path volumes** (e.g., `./hub` for `whisperlive`): Become problematic in multi-node setups unless data is replicated on all potential nodes or you use node constraints to tie services to specific nodes with that data. For true multi-node, consider Swarm-aware volume drivers (NFS, etc.).

---
*Previous generic notes on `docker-compose.yml` differences with Swarm still apply (build ignored, depends_on for startup order, deploy key is king, etc.)* 