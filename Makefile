# Makefile for VEXA-CPU GCP Swarm Deployment

# Load environment variables from .env.gcp
# This ensures that all gcloud commands use the correct project, region, names, etc.
include .env.gcp

# Export variables for use in shell commands within recipes
export GCP_PROJECT_ID GCP_REGION GCP_ZONE ARTIFACT_REGISTRY_NAME SQL_INSTANCE_NAME SQL_TIER SQL_ROOT_PASSWORD SQL_DATABASE_VERSION DB_NAME DB_USER DB_PASSWORD REDIS_INSTANCE_NAME REDIS_TIER REDIS_SIZE_GB VM_MANAGER_NAME VM_MACHINE_TYPE VM_DISK_SIZE VM_IMAGE_FAMILY VM_IMAGE_PROJECT VM_MANAGER_TAG NETWORK_NAME FIREWALL_RULE_SWARM_MANAGER FIREWALL_RULE_TRAEFIK TRAEFIK_HOST STACK_NAME

# Define image prefix as a Make variable for global use in this Makefile
IMAGE_PREFIX_MAKEVAR := $(GCP_REGION)-docker.pkg.dev/$(GCP_PROJECT_ID)/$(ARTIFACT_REGISTRY_NAME)

# Default target
.PHONY: all
all: help

# Get the directory of the Makefile
# Useful for sourcing scripts or referencing files relative to the Makefile
MAKEFILE_DIR := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))

# Target to display help information
.PHONY: help
help:
	@echo "----------------------------------------------------------------------"
	@echo "VEXA-CPU GCP Swarm Deployment Makefile"
	@echo "----------------------------------------------------------------------"
	@echo "Usage: make [target]"
	@echo ""
	@echo "Configuration:"
	@echo "  Ensure '.env.gcp' is configured with your GCP project, region, names, and credentials."
	@echo ""
	@echo "Main Targets:"
	@echo "  gcp-infra-provision    - Provision all necessary GCP infrastructure (VM, SQL, Redis, AR, Firewall)."
	@echo "  gcp-infra-destroy      - Destroy all GCP infrastructure created by this Makefile."
	@echo "  update-env-ips         - Fetches IPs of created resources and updates .env.gcp."
	@echo ""
	@echo "Individual Infrastructure Targets:"
	@echo "  gcp-project-setup      - Set active project and enable necessary APIs."
	@echo "  gcp-ar-create          - Create Artifact Registry repository."
	@echo "  gcp-sql-create         - Create Cloud SQL (PostgreSQL) instance."
	@echo "  gcp-redis-create       - Create Memorystore (Redis) instance."
	@echo "  gcp-vm-create          - Create Compute Engine VM for Swarm manager."
	@echo "  gcp-firewall-create    - Create firewall rules."
	@echo "  gcp-db-create-user     - Create application user and database in Cloud SQL (after instance is ready)."
	@echo ""
	@echo "  gcp-vm-ssh             - SSH into the Swarm manager VM."
	@echo "  gcp-vm-get-ip          - Get external IP of the Swarm manager VM."
	@echo ""
	@echo "Future Deployment Targets (to be implemented):"
	@echo "  images-auth            - Configure Docker to authenticate with Artifact Registry."
	@echo "  images-build-push      - Build and push Docker images."
	@echo "  swarm-init             - Initialize Docker Swarm on the manager VM."
	@echo "  stack-deploy           - Deploy the Docker Swarm stack."
	@echo "  stack-remove           - Remove the Docker Swarm stack."
	@echo "  status                 - Show deployment status."
	@echo "----------------------------------------------------------------------"

# --- GCP Infrastructure Provisioning ---

.PHONY: gcp-project-setup
gcp-project-setup:
	@echo "\n=== Setting active GCP project and enabling necessary APIs... ==="
	gcloud config set project $(GCP_PROJECT_ID)
	@echo "Enabling required Google Cloud services. This may take a few minutes..."
	gcloud services enable \
		compute.googleapis.com \
		sqladmin.googleapis.com \
		redis.googleapis.com \
		artifactregistry.googleapis.com \
		servicenetworking.googleapis.com # Required for private IP for SQL/Redis
	@echo "GCP project setup complete."

.PHONY: gcp-ar-create
gcp-ar-create:
	@echo "\n=== Creating Artifact Registry repository: $(ARTIFACT_REGISTRY_NAME)... ==="
	gcloud artifacts repositories create $(ARTIFACT_REGISTRY_NAME) \
		--repository-format=docker \
		--location=$(GCP_REGION) \
		--description="$(ARTIFACT_REGISTRY_DESCRIPTION)" \
		--project=$(GCP_PROJECT_ID) || echo "Artifact Registry repository already exists or an error occurred."
	@echo "Artifact Registry creation attempt complete."

.PHONY: gcp-sql-create
gcp-sql-create:
	@echo "\n=== Creating Cloud SQL (PostgreSQL) instance: $(SQL_INSTANCE_NAME)... This will take several minutes. ==="
	# Check if instance already exists
	@(gcloud sql instances describe $(SQL_INSTANCE_NAME) --project=$(GCP_PROJECT_ID) > /dev/null 2>&1 && \
	echo "Cloud SQL instance $(SQL_INSTANCE_NAME) already exists. Skipping creation.") || \
	(gcloud sql instances create $(SQL_INSTANCE_NAME) \
		--database-version=$(SQL_DATABASE_VERSION) \
		--tier=$(SQL_TIER) \
		--region=$(GCP_REGION) \
		--root-password='$(SQL_ROOT_PASSWORD)' \
		--project=$(GCP_PROJECT_ID) \
		--network=projects/$(GCP_PROJECT_ID)/global/networks/$(NETWORK_NAME) \
		--no-assign-ip && \
	 echo "Cloud SQL instance $(SQL_INSTANCE_NAME) creation initiated. Use 'gcloud sql instances describe $(SQL_INSTANCE_NAME)' to check status.")
	@echo "Cloud SQL creation attempt complete."

.PHONY: gcp-redis-create
gcp-redis-create:
	@echo "\n=== Creating Memorystore (Redis) instance: $(REDIS_INSTANCE_NAME)... This may take a few minutes. ==="
	# Check if instance already exists
	@(gcloud redis instances describe $(REDIS_INSTANCE_NAME) --region=$(GCP_REGION) --project=$(GCP_PROJECT_ID) > /dev/null 2>&1 && \
	echo "Memorystore Redis instance $(REDIS_INSTANCE_NAME) already exists. Skipping creation.") || \
	(gcloud redis instances create $(REDIS_INSTANCE_NAME) \
		--size=$(REDIS_SIZE_GB) \
		--region=$(GCP_REGION) \
		--tier=$(REDIS_TIER) \
		--redis-version=redis_6_x \
		--network=projects/$(GCP_PROJECT_ID)/global/networks/$(NETWORK_NAME) \
		--connect-mode=PRIVATE_SERVICE_ACCESS \
		--project=$(GCP_PROJECT_ID) && \
	 echo "Memorystore Redis instance $(REDIS_INSTANCE_NAME) creation initiated. Use 'gcloud redis instances describe $(REDIS_INSTANCE_NAME) --region=$(GCP_REGION)' to check status.")
	@echo "Memorystore Redis creation attempt complete."

.PHONY: gcp-vm-create
gcp-vm-create:
	@echo "\n=== Creating Compute Engine VM: $(VM_MANAGER_NAME)... ==="
	# Check if VM already exists
	@(gcloud compute instances describe $(VM_MANAGER_NAME) --zone=$(GCP_ZONE) --project=$(GCP_PROJECT_ID) > /dev/null 2>&1 && \
	echo "Compute Engine VM $(VM_MANAGER_NAME) already exists. Skipping creation.") || \
	(gcloud compute instances create $(VM_MANAGER_NAME) \
		--project=$(GCP_PROJECT_ID) \
		--zone=$(GCP_ZONE) \
		--machine-type=$(VM_MACHINE_TYPE) \
		--boot-disk-size=$(VM_DISK_SIZE) \
		--boot-disk-type=pd-standard \
		--boot-disk-device-name=$(VM_MANAGER_NAME)-disk \
		--boot-disk-auto-delete \
		--image-family=$(VM_IMAGE_FAMILY) \
		--image-project=$(VM_IMAGE_PROJECT) \
		--tags=$(VM_MANAGER_TAG) \
		--tags=http-server \
		--tags=https-server \
		--scopes=cloud-platform \
		--metadata-from-file startup-script=./startup-script.sh && \
	 echo "Compute Engine VM $(VM_MANAGER_NAME) creation initiated.")
	@echo "Compute Engine VM creation attempt complete."

.PHONY: gcp-firewall-create
gcp-firewall-create:
	@echo "\n=== Creating Firewall Rules... ==="
	# Allow SSH, HTTP, HTTPS, Traefik Dashboard (standard ports)
	@(gcloud compute firewall-rules describe $(FIREWALL_RULE_TRAEFIK) --project=$(GCP_PROJECT_ID) > /dev/null 2>&1 && \
	  echo "Firewall rule $(FIREWALL_RULE_TRAEFIK) already exists. Skipping.") || \
	 (gcloud compute firewall-rules create $(FIREWALL_RULE_TRAEFIK) \
		--project=$(GCP_PROJECT_ID) \
		--network=$(NETWORK_NAME) \
		--allow=tcp:22,tcp:80,tcp:443,tcp:$(TRAEFIK_DASHBOARD_PORT) \
		--target-tags=$(VM_MANAGER_TAG) \
		--source-ranges=0.0.0.0/0 \
		--description="Allow HTTP, HTTPS, SSH, and Traefik Dashboard access to Swarm manager")

	# Allow Swarm manager node communication (if you expand to a multi-node Swarm)
	@(gcloud compute firewall-rules describe $(FIREWALL_RULE_SWARM_MANAGER) --project=$(GCP_PROJECT_ID) > /dev/null 2>&1 && \
	  echo "Firewall rule $(FIREWALL_RULE_SWARM_MANAGER) already exists. Skipping.") || \
	 (gcloud compute firewall-rules create $(FIREWALL_RULE_SWARM_MANAGER) \
		--project=$(GCP_PROJECT_ID) \
		--network=$(NETWORK_NAME) \
		--allow=tcp:2376,tcp:2377,tcp:7946,udp:7946,udp:4789 \
		--target-tags=$(VM_MANAGER_TAG) \
		--source-tags=$(VM_MANAGER_TAG) \
		--description="Allow Swarm manager node communication (control plane, data plane, overlay network)")
	@echo "Firewall rule creation attempt complete."

.PHONY: gcp-db-create-user
gcp-db-create-user:
	@echo "\n=== Creating database '$(DB_NAME)' and user '$(DB_USER)' in Cloud SQL instance '$(SQL_INSTANCE_NAME)'... ==="
	@echo "Waiting for SQL instance to be runnable... (This might take a moment if just created)"
	@while ! gcloud sql instances describe $(SQL_INSTANCE_NAME) --project=$(GCP_PROJECT_ID) --format='value(state)' | grep -q RUNNABLE; do echo -n '.'; sleep 10; done; echo " Instance is RUNNABLE."
	# Check if database exists
	@(gcloud sql databases describe $(DB_NAME) --instance=$(SQL_INSTANCE_NAME) --project=$(GCP_PROJECT_ID) > /dev/null 2>&1 && \
	  echo "Database $(DB_NAME) already exists. Skipping creation.") || \
	 (gcloud sql databases create $(DB_NAME) --instance=$(SQL_INSTANCE_NAME) --project=$(GCP_PROJECT_ID))
	# Check if user exists
	@(gcloud sql users list --instance=$(SQL_INSTANCE_NAME) --project=$(GCP_PROJECT_ID) --format='value(name)' | grep -qw $(DB_USER) && \
	  echo "User $(DB_USER) already exists. Skipping creation.") || \
	 (gcloud sql users create $(DB_USER) --instance=$(SQL_INSTANCE_NAME) --password='$(DB_PASSWORD)' --project=$(GCP_PROJECT_ID))
	@echo "Database and user setup attempt complete."


# --- Update .env.gcp with Resource IPs ---
.PHONY: update-env-ips
update-env-ips:
	@echo "\n=== Fetching resource IPs and updating .env.gcp... ==="
	@echo "Fetching VM External IP..."
	@VM_EXTERNAL_IP=$$(gcloud compute instances describe $(VM_MANAGER_NAME) --zone=$(GCP_ZONE) --project=$(GCP_PROJECT_ID) --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "NOT_FOUND"); \
	if [ "$$VM_EXTERNAL_IP" = "NOT_FOUND" ] || [ -z "$$VM_EXTERNAL_IP" ]; then \
	  echo "ERROR: Could not retrieve External IP for VM $(VM_MANAGER_NAME). Ensure VM exists and is running."; \
	else \
	  echo "VM External IP: $$VM_EXTERNAL_IP"; \
	  sed -i "s|^VM_MANAGER_EXTERNAL_IP=.*|VM_MANAGER_EXTERNAL_IP=\"$$VM_EXTERNAL_IP\"|" .env.gcp; \
	  NEW_TRAEFIK_HOST=$$(echo $(TRAEFIK_HOST) | sed "s/{{VM_EXTERNAL_IP}}/$$VM_EXTERNAL_IP/"); \
	  echo "Updating TRAEFIK_HOST to: $$NEW_TRAEFIK_HOST"; \
	  sed -i "s|^TRAEFIK_HOST=.*|TRAEFIK_HOST=\"$$NEW_TRAEFIK_HOST\"|" .env.gcp; \
	fi

	@echo "Fetching VM Internal IP..."
	@VM_INTERNAL_IP=$$(gcloud compute instances describe $(VM_MANAGER_NAME) --zone=$(GCP_ZONE) --project=$(GCP_PROJECT_ID) --format='get(networkInterfaces[0].networkIP)' 2>/dev/null || echo "NOT_FOUND"); \
	if [ "$$VM_INTERNAL_IP" = "NOT_FOUND" ] || [ -z "$$VM_INTERNAL_IP" ]; then \
	  echo "ERROR: Could not retrieve Internal IP for VM $(VM_MANAGER_NAME)."; \
	else \
	  echo "VM Internal IP: $$VM_INTERNAL_IP"; \
	  sed -i "s|^VM_MANAGER_INTERNAL_IP=.*|VM_MANAGER_INTERNAL_IP=\"$$VM_INTERNAL_IP\"|" .env.gcp; \
	fi

	@echo "Fetching Cloud SQL Private IP..."
	@DB_HOST_IP=$$(gcloud sql instances describe $(SQL_INSTANCE_NAME) --project=$(GCP_PROJECT_ID) --format='get(ipAddresses[?(@.type=="PRIVATE")].ipAddress)' 2>/dev/null || echo "NOT_FOUND"); \
	if [ "$$DB_HOST_IP" = "NOT_FOUND" ] || [ -z "$$DB_HOST_IP" ]; then \
	  echo "ERROR: Could not retrieve Private IP for SQL instance $(SQL_INSTANCE_NAME). Ensure instance exists, is running, and has a private IP."; \
	else \
	  echo "Cloud SQL Private IP: $$DB_HOST_IP"; \
	  sed -i "s|^DB_HOST_IP=.*|DB_HOST_IP=\"$$DB_HOST_IP\"|" .env.gcp; \
	  sed -i "s|^DB_HOST=.*|DB_HOST=\"$$DB_HOST_IP\"|" .env.gcp; \
	fi

	@echo "Fetching Memorystore Redis Host IP (Private IP)..."
	@REDIS_HOST_IP=$$(gcloud redis instances describe $(REDIS_INSTANCE_NAME) --region=$(GCP_REGION) --project=$(GCP_PROJECT_ID) --format='get(host)' 2>/dev/null || echo "NOT_FOUND"); \
	if [ "$$REDIS_HOST_IP" = "NOT_FOUND" ] || [ -z "$$REDIS_HOST_IP" ]; then \
	  echo "ERROR: Could not retrieve Host IP for Redis instance $(REDIS_INSTANCE_NAME). Ensure instance exists and is running."; \
	else \
	  echo "Redis Host IP: $$REDIS_HOST_IP"; \
	  sed -i "s|^REDIS_HOST_IP=.*|REDIS_HOST_IP=\"$$REDIS_HOST_IP\"|" .env.gcp; \
	  sed -i "s|^REDIS_HOST=.*|REDIS_HOST=\"$$REDIS_HOST_IP\"|" .env.gcp; \
	fi
	@echo "IP update process complete. Check .env.gcp."

# --- Full Infrastructure Provisioning Target ---
.PHONY: gcp-infra-provision
gcp-infra-provision: gcp-project-setup gcp-ar-create gcp-sql-create gcp-redis-create gcp-vm-create gcp-firewall-create
	@echo "\n=== Waiting for all infrastructure to stabilize before creating DB user and updating IPs... ==="
	@echo "This might take a few minutes. Cloud SQL and Redis can take time to become fully available after creation."
	@sleep 120 # General wait time, might need adjustment
	$(MAKE) gcp-db-create-user
	$(MAKE) update-env-ips
	@echo "\n=== GCP Infrastructure Provisioning Complete ==="
	@echo "Review .env.gcp for updated IP addresses."
	@echo "Next steps typically involve: make images-auth, make images-build-push, make swarm-init, make stack-deploy"

# --- GCP Infrastructure Destruction (Use with caution!) ---
.PHONY: gcp-infra-destroy
gcp-infra-destroy:
	@echo "\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
	@echo "WARNING: This will attempt to delete GCP resources defined in .env.gcp."
	@echo "VM: $(VM_MANAGER_NAME), SQL: $(SQL_INSTANCE_NAME), Redis: $(REDIS_INSTANCE_NAME), AR: $(ARTIFACT_REGISTRY_NAME)"
	@echo "Firewall rules: $(FIREWALL_RULE_TRAEFIK), $(FIREWALL_RULE_SWARM_MANAGER)"
	@echo "This operation is IRREVERSIBLE and will lead to data loss for these resources."
	@read -p "Type 'DELETE' to confirm: " confirm && [ "$$confirm" = "DELETE" ] || (echo "Aborted." && exit 1)
	@echo "Proceeding with deletion..."

	@echo "Deleting Firewall Rule $(FIREWALL_RULE_TRAEFIK)..."
	gcloud compute firewall-rules delete $(FIREWALL_RULE_TRAEFIK) --project=$(GCP_PROJECT_ID) --quiet || echo "Rule already deleted or error."
	@echo "Deleting Firewall Rule $(FIREWALL_RULE_SWARM_MANAGER)..."
	gcloud compute firewall-rules delete $(FIREWALL_RULE_SWARM_MANAGER) --project=$(GCP_PROJECT_ID) --quiet || echo "Rule already deleted or error."

	@echo "Deleting Compute Engine VM $(VM_MANAGER_NAME)..."
	gcloud compute instances delete $(VM_MANAGER_NAME) --zone=$(GCP_ZONE) --project=$(GCP_PROJECT_ID) --quiet || echo "VM already deleted or error."

	@echo "Deleting Cloud SQL instance $(SQL_INSTANCE_NAME)... This may take a few minutes."
	gcloud sql instances delete $(SQL_INSTANCE_NAME) --project=$(GCP_PROJECT_ID) --quiet || echo "SQL instance already deleted or error."

	@echo "Deleting Memorystore Redis instance $(REDIS_INSTANCE_NAME)... This may take a few minutes."
	gcloud redis instances delete $(REDIS_INSTANCE_NAME) --region=$(GCP_REGION) --project=$(GCP_PROJECT_ID) --quiet || echo "Redis instance already deleted or error."

	@echo "Deleting Artifact Registry repository $(ARTIFACT_REGISTRY_NAME)..."
	@echo "Note: Repository deletion might fail if it contains images. Manual deletion might be required from GCP console."
	gcloud artifacts repositories delete $(ARTIFACT_REGISTRY_NAME) --location=$(GCP_REGION) --project=$(GCP_PROJECT_ID) --quiet || echo "AR repo already deleted or error (may need to be empty)."

	@echo "Infrastructure deletion attempt complete."


# --- Helper Targets ---
.PHONY: gcp-vm-ssh
gcp-vm-ssh:
	@echo "Attempting to SSH into $(VM_MANAGER_NAME)..."
	gcloud compute ssh --project $(GCP_PROJECT_ID) --zone $(GCP_ZONE) $(VM_MANAGER_NAME)

.PHONY: gcp-vm-get-ip
gcp-vm-get-ip:
	@echo "External IP for $(VM_MANAGER_NAME):"
	@gcloud compute instances describe $(VM_MANAGER_NAME) --zone=$(GCP_ZONE) --project=$(GCP_PROJECT_ID) --format='get(networkInterfaces[0].accessConfigs[0].natIP)'


# --- Placeholder Deployment Targets (To be implemented later) ---
.PHONY: images-auth
images-auth:
	@echo "\n=== Authenticating Docker with GCP Artifact Registry: $(GCP_REGION)-docker.pkg.dev ==="
	gcloud auth configure-docker $(GCP_REGION)-docker.pkg.dev --quiet
	@echo "Docker authentication configured."

.PHONY: images-build-push
images-build-push:
	@echo "\n=== Building and pushing Docker images... ==="
	@{ \
	  echo "Using image prefix: $(IMAGE_PREFIX_MAKEVAR)"; \
	  \
	  SERVICES_TO_BUILD="api-gateway admin-api bot-manager WhisperLive transcription-collector vexa-bot"; \
	  SERVICE_IMAGE_NAMES="vexa-api-gateway vexa-admin-api vexa-bot-manager vexa-whisperlive-cpu vexa-transcription-collector vexa-bot"; \
	  DOCKERFILE_NAMES="Dockerfile Dockerfile Dockerfile Dockerfile.cpu Dockerfile Dockerfile"; \
	  \
	  service_count=1; \
	  for SERVICE_DIR in $$SERVICES_TO_BUILD; do \
	    IMAGE_NAME=$$(echo $$SERVICE_IMAGE_NAMES | awk -v sc="$$service_count" '{print $$sc}'); \
	    DOCKERFILE_NAME=$$(echo $$DOCKERFILE_NAMES | awk -v sc="$$service_count" '{print $$sc}'); \
	    FULL_IMAGE_NAME=\"$(IMAGE_PREFIX_MAKEVAR)/$$IMAGE_NAME:latest\"; \
	    echo "\n--- Building $$FULL_IMAGE_NAME from ./services/$$SERVICE_DIR using $$DOCKERFILE_NAME ---"; \
	    if [ -f \"./services/$$SERVICE_DIR/$$DOCKERFILE_NAME\" ]; then \
	      docker build -t \"$$FULL_IMAGE_NAME\" -f \"./services/$$SERVICE_DIR/$$DOCKERFILE_NAME\" . || { echo \"ERROR: Docker build failed for $$SERVICE_DIR\"; exit 1; }; \
	      echo \"--- Pushing $$FULL_IMAGE_NAME ---\"; \
	      docker push \"$$FULL_IMAGE_NAME\" || { echo \"ERROR: Docker push failed for $$FULL_IMAGE_NAME\"; exit 1; }; \
	    else \
	      echo \"WARNING: No Dockerfile found in ./services/$$SERVICE_DIR. Skipping.\"; \
	    fi; \
	    service_count=$$(($$service_count + 1)); \
	  done; \
	  echo "\n=== Docker image build and push complete. ==="; \
	}

.PHONY: swarm-init
swarm-init:
	@echo "\n=== Initializing Docker Swarm on manager VM: $(VM_MANAGER_NAME) ==="
	@echo "This involves SSHing to the VM to run commands."
	@VM_INTERNAL_IP=$$(gcloud compute instances describe $(VM_MANAGER_NAME) --zone=$(GCP_ZONE) --project=$(GCP_PROJECT_ID) --format='get(networkInterfaces[0].networkIP)' 2>/dev/null || echo "NOT_FOUND"); \
	if [ "$$VM_INTERNAL_IP" = "NOT_FOUND" ] || [ -z "$$VM_INTERNAL_IP" ]; then \
	  echo "ERROR: Could not retrieve Internal IP for VM $(VM_MANAGER_NAME). Cannot initialize Swarm."; \
	  exit 1; \
	fi; \
	@echo "Using VM Internal IP for Swarm advertise address: $$VM_INTERNAL_IP"; \
	gcloud compute ssh $(VM_MANAGER_NAME) --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID) -- \
	  "sudo docker swarm init --advertise-addr $$VM_INTERNAL_IP && \
	   echo 'Swarm initialized.' || echo 'Swarm already initialized or error during init.'"

	@echo "\n=== Copying traefik.toml to manager VM... ==="
	gcloud compute scp ./traefik.toml $(VM_MANAGER_NAME):~/traefik.toml --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID)

	@echo "\n=== Creating Traefik Docker Swarm config on manager VM... ==="
	gcloud compute ssh $(VM_MANAGER_NAME) --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID) -- \
	  "sudo docker config inspect traefik_config > /dev/null 2>&1 && \
	   echo 'Docker config traefik_config already exists. Skipping creation.' || \
	   (sudo docker config create traefik_config ~/traefik.toml && \
	    echo 'Docker config traefik_config created.' || echo 'Error creating Docker config traefik_config.')"
	@echo "\n=== Swarm setup attempt complete. ==="

.PHONY: vm-docker-auth
vm-docker-auth:
	@echo "\n=== Authenticating Docker on VM: $(VM_MANAGER_NAME) with GCP Artifact Registry ==="
	gcloud compute ssh $(VM_MANAGER_NAME) --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID) -- \
	  "sudo gcloud auth configure-docker $(GCP_REGION)-docker.pkg.dev --quiet"
	@echo "Docker authentication configured on VM."

.PHONY: stack-deploy
stack-deploy:
	@echo "DEBUG: Local IMAGE_PREFIX_MAKEVAR is [$(IMAGE_PREFIX_MAKEVAR)]"
	@echo "\n=== Deploying Docker Swarm stack: $(STACK_NAME) to manager VM: $(VM_MANAGER_NAME) ==="
	@echo "Copying docker-compose.gcp-cpu.yml to manager VM..."
	gcloud compute scp ./docker-compose.gcp-cpu.yml $(VM_MANAGER_NAME):~/docker-compose.gcp-cpu.yml --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID)

	@echo "\nPreparing environment file .vm_env.sh for VM..."
	@# Create .vm_env.sh with clean export statements
	@echo "export IMAGE_PREFIX='$(IMAGE_PREFIX_MAKEVAR)'" > .vm_env.sh
	@# Extract, clean, and append other necessary vars from .env.gcp
	@cat .env.gcp | grep -E '^DB_HOST=|^DB_PORT=|^DB_NAME=|^DB_USER=|^DB_PASSWORD=|^REDIS_HOST=|^REDIS_PORT=|^ADMIN_API_TOKEN=|^LOG_LEVEL=|^TRAEFIK_HOST=|^LANGUAGE_DETECTION_SEGMENTS=|^VAD_FILTER_THRESHOLD=|^TRAEFIK_WEB_PORT=|^TRAEFIK_DASHBOARD_PORT=' | \
		awk -F'=' '{ V = $$2; gsub(/^"/, "", V); gsub(/" *#.*$$/, "", V); gsub(/"$$/, "", V); gsub(/ *#.*$$/, "", V); printf "export %s=\x27%s\x27\n", $$1, V }' >> .vm_env.sh

	@echo "Copying .vm_env.sh to manager VM..."
	gcloud compute scp ./.vm_env.sh $(VM_MANAGER_NAME):~/.vm_env.sh --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID)
	@rm .vm_env.sh # Clean up local temp file

	@echo "\nDeploying stack on VM..."
	gcloud compute ssh $(VM_MANAGER_NAME) --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID) -- \
	  "cd ~ && \
	   echo 'Sourcing environment variables from .vm_env.sh...' && \
	   source .vm_env.sh && \
	   echo \"IMAGE_PREFIX on VM after source: [$${IMAGE_PREFIX}]\" && \
	   echo \"DB_HOST on VM after source: [$${DB_HOST}]\" && \
	   echo \"REDIS_HOST on VM after source: [$${REDIS_HOST}]\" && \
	   sudo -E docker stack deploy -c ~/docker-compose.gcp-cpu.yml --with-registry-auth $(STACK_NAME)"
	@echo "\n=== Stack deployment attempt complete. ==="
	@echo "Run 'make status' or 'make stack-ps' to check service status on the VM."

.PHONY: stack-remove
stack-remove:
	@echo "\n=== Removing Docker Swarm stack: $(STACK_NAME) from manager VM: $(VM_MANAGER_NAME) ==="
	gcloud compute ssh $(VM_MANAGER_NAME) --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID) -- \
	  "sudo docker stack rm $(STACK_NAME) && \
	   echo 'Stack $(STACK_NAME) removal initiated.' || echo 'Error removing stack $(STACK_NAME) or stack not found.'"
	@echo "\n=== Stack removal attempt complete. ==="

.PHONY: stack-ps
stack-ps:
	@echo "\n=== Status of Docker Swarm stack: $(STACK_NAME) on manager VM: $(VM_MANAGER_NAME) ==="
	gcloud compute ssh $(VM_MANAGER_NAME) --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID) -- \
	  "sudo docker stack ps $(STACK_NAME)"

.PHONY: stack-logs
stack-logs:
	@echo "\n=== Logs for Docker Swarm stack: $(STACK_NAME) on manager VM: $(VM_MANAGER_NAME) ==="
	@echo "(Specify SERVICE_NAME=your_service_name to see logs for a specific service, e.g., make stack-logs SERVICE_NAME=api-gateway)"
	gcloud compute ssh $(VM_MANAGER_NAME) --zone $(GCP_ZONE) --project $(GCP_PROJECT_ID) -- \
	  "sudo docker service logs $(STACK_NAME)_$(SERVICE_NAME) --follow --tail 50 || sudo docker stack ps $(STACK_NAME) && echo 'Showing all stack tasks if service name was not found or invalid. To see specific service logs, provide a valid SERVICE_NAME argument to make. For example: make stack-logs SERVICE_NAME=api-gateway'"

.PHONY: status
status:
	@echo "\n=== Current GCP Infrastructure and Stack Status ==="
	@echo "--- .env.gcp values ---"
	@cat .env.gcp | grep -E 'GCP_PROJECT_ID|GCP_REGION|VM_MANAGER_NAME|VM_MANAGER_EXTERNAL_IP|SQL_INSTANCE_NAME|DB_HOST|REDIS_INSTANCE_NAME|REDIS_HOST|TRAEFIK_HOST|STACK_NAME' || echo "No .env.gcp values found or grep error."
	@echo "\n--- Swarm Manager VM Status (vexa-manager-1) ---"
	@gcloud compute instances describe $(VM_MANAGER_NAME) --zone=$(GCP_ZONE) --project=$(GCP_PROJECT_ID) --format='table(name,status,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)' || echo "Failed to get VM status."
	@echo "\n--- Docker Stack Services (on VM) ---"
	@make --no-print-directory stack-ps
	@echo "\n--- Traefik Dashboard (if accessible) ---"
	@echo "Potentially at: http://$(TRAEFIK_HOST):$(TRAEFIK_DASHBOARD_PORT) (TRAEFIK_HOST from .env.gcp)"
	@echo "\nFor detailed service logs: make stack-logs SERVICE_NAME=<service_short_name> (e.g., api-gateway)" 