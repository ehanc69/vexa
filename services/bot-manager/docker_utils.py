import docker # Official Docker SDK
from docker.types import ServiceMode, TaskTemplate, ContainerSpec, RestartPolicy, Mount # Common Swarm types
# from docker.types.networks import NetworkAttachment # Direct import for NetworkAttachment - REMOVED
from docker.errors import APIError, NotFound as DockerNotFound # Docker SDK errors
import logging
import json
import uuid
import os
import time # Keep for now, might be used in retry logic if any
from typing import Optional, List, Dict, Any
from datetime import datetime, timezone
import asyncio

# Remove old socket/requests related imports
# import requests_unixsocket
# import requests
# from requests.exceptions import RequestException, ConnectionError, HTTPError

# Import the Platform class from shared models
from shared_models.schemas import Platform # Keep

# ---> ADD Missing imports for _record_session_start (Keep if still relevant, or remove if logic changes)
from shared_models.database import async_session_local
from shared_models.models import MeetingSession, Meeting
# <--- END ADD

# ---> ADD Missing imports for check logic & session start (Keep if still relevant)
from fastapi import HTTPException # For raising limit error
from app.database.service import TranscriptionService # To get user limit
from sqlalchemy.future import select
from shared_models.models import User # MeetingSession already imported
# <--- END ADD

# Assuming these are still needed from config or env
# DOCKER_HOST is no longer directly used by docker.from_env() if socket is default
# DOCKER_HOST = os.environ.get("DOCKER_HOST", "unix://var/run/docker.sock") # Not needed by docker.from_env() usually
DOCKER_NETWORK = os.environ.get("DOCKER_NETWORK", "vexa_vexa_default") # CRITICAL: This must be the Swarm overlay network name
BOT_IMAGE_NAME = os.environ.get("BOT_IMAGE_NAME", "vexa-bot:dev") # This will be the image for the vexa-bot service
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")

DEVICE_TYPE = os.environ.get("DEVICE_TYPE", "cuda").lower()

logger = logging.getLogger("bot_manager.docker_utils")

# Global Docker client
_docker_client = None

# Define a local exception (can be removed if Docker SDK exceptions are sufficient)
# class DockerConnectionError(Exception):
#     pass

def get_docker_client(max_retries=3, delay=2):
    """Initializes and returns a Docker SDK client with retries if needed."""
    global _docker_client
    if _docker_client is None:
        logger.info("Attempting to initialize Docker SDK client...")
        retries = 0
        while retries < max_retries:
            try:
                temp_client = docker.from_env()
                # Test connection by getting Docker version
                version_data = temp_client.version()
                api_version = version_data.get('ApiVersion')
                logger.info(f"Docker SDK client initialized. Docker API version: {api_version}")
                _docker_client = temp_client # Assign only on success
                return _docker_client
            except APIError as e: # Catch Docker SDK specific API errors
                logger.warning(f"Attempt {retries+1}/{max_retries}: Docker API error during client initialization: {e}. Retrying in {delay}s...")
            except Exception as e: # Catch other potential errors (e.g., if Docker daemon is not running)
                logger.error(f"Attempt {retries+1}/{max_retries}: Failed to initialize Docker SDK client: {e}", exc_info=True)

            retries += 1
            if retries < max_retries:
                time.sleep(delay)
            else:
                logger.error(f"Failed to connect to Docker via SDK after {max_retries} attempts.")
                _docker_client = None # Ensure it's None on failure
                raise DockerNotFound(f"Could not connect to Docker via SDK after {max_retries} attempts.") # Raise DockerNotFound or a custom error

    return _docker_client

# The old close_docker_client is not strictly necessary for the SDK client
# as it doesn't maintain an open session in the same way requests_unixsocket did.
# However, if there are resources to be cleaned up by the client, its close method can be called.
# For now, we'll remove it. If explicit cleanup is needed, a new function can be added.

# def close_docker_client():
#     global _docker_client
#     if _docker_client:
#         logger.info("Closing Docker SDK client (if applicable).")
#         try:
#             # The standard Docker client from from_env() doesn't have an explicit close() method
#             # that releases resources like a requests.Session.
#             # If using a custom APIClient, it might have client.close().
#             pass
#         except Exception as e:
#             logger.warning(f"Error during Docker SDK client cleanup: {e}")
#         _docker_client = None

# Helper async function to record session start
async def _record_session_start(meeting_id: int, connection_id: str):
    """Helper to record the session start in the database."""
    # This function might need adjustment based on how connection_id maps to MeetingSession
    # Assuming connection_id is unique and can identify the session.
    async with async_session_local() as db:
        try:
            # Find the meeting
            meeting_result = await db.execute(select(Meeting).filter(Meeting.id == meeting_id))
            meeting = meeting_result.scalar_one_or_none()

            if not meeting:
                logger.error(f"Meeting with ID {meeting_id} not found for recording session start.")
                return

            # Create a new session entry
            new_session = MeetingSession(
                meeting_id=meeting_id,
                connection_id=connection_id, # Assuming connection_id can be stored
                status="active", # Or some initial status
                # started_at will be set by default
            )
            db.add(new_session)
            await db.commit()
            logger.info(f"Recorded session start for meeting_id {meeting_id}, connection_id {connection_id}")
        except Exception as e:
            await db.rollback()
            logger.error(f"Database error recording session start for meeting {meeting_id}: {e}", exc_info=True)

# Make the function async
async def start_bot_container(
    user_id: int,
    meeting_id: int,
    meeting_url: Optional[str],
    platform: str, # External name (e.g., google_meet)
    bot_name: Optional[str],
    user_token: str,
    native_meeting_id: str,
    language: Optional[str],
    task: Optional[str]
) -> Optional[tuple[str, str]]: # Returns (service_id, connection_id)
    """
    Starts a vexa-bot Swarm service AFTER checking user limit.
    Each bot runs as a separate Swarm service.
    Args:
        user_id: The ID of the user requesting the bot.
        meeting_id: Internal database ID of the meeting.
        meeting_url: The URL for the bot to join.
        platform: The meeting platform (external name).
        bot_name: An optional name for the bot inside the meeting.
        user_token: The API token of the user requesting the bot.
        native_meeting_id: The platform-specific meeting ID (e.g., 'xyz-abc-pdq').
        language: Optional language code for transcription.
        task: Optional transcription task ('transcribe' or 'translate').
        
    Returns:
        A tuple (service_id, connection_id) if successful, None otherwise.
    """
    client = None
    try:
        client = get_docker_client()
    except DockerNotFound as e:
        logger.error(f"Failed to get Docker client: {e}")
        raise HTTPException(status_code=500, detail="Docker connection error.")
    
    if not client:
         logger.error("Docker client not available after get_docker_client call.") # Should be caught by exception
         raise HTTPException(status_code=500, detail="Docker client unavailable.")

    # === START: Bot Limit Check ===
    try:
        user = await TranscriptionService.get_or_create_user(user_id)
        if not user:
             logger.error(f"User with ID {user_id} not found for bot limit check.")
             raise HTTPException(status_code=404, detail=f"User {user_id} not found.")

        if not hasattr(user, 'max_concurrent_bots') or user.max_concurrent_bots is None:
             logger.error(f"User {user_id} is missing the max_concurrent_bots attribute or it's not set.")
             raise HTTPException(status_code=500, detail="User configuration error: Bot limit not set.")
        
        user_limit = user.max_concurrent_bots

        # Count currently running bot *services* for this user using labels
        # Each bot is a service, so we count services.
        service_label_filter = f"vexa.user_id={user_id}"
        try:
            running_bot_services = client.services.list(filters={"label": service_label_filter})
            current_bot_count = len(running_bot_services)
            logger.debug(f"[Limit Check] Found {current_bot_count} running bot services for user {user_id} with label '{service_label_filter}'. Limit: {user_limit}")
        except APIError as api_err:
            logger.error(f"[Limit Check] Docker API error counting services for user {user_id}: {api_err}", exc_info=True)
            raise HTTPException(status_code=500, detail="Failed to verify current bot count due to Docker API error.")
        except Exception as count_err:
            logger.error(f"[Limit Check] Unexpected error counting services for user {user_id}: {count_err}", exc_info=True)
            raise HTTPException(status_code=500, detail="Failed to process bot count verification.")

        if current_bot_count >= user_limit:
            logger.warning(f"User {user_id} reached bot limit ({current_bot_count}/{user_limit}). Cannot start new bot.")
            raise HTTPException(
                status_code=403,
                detail=f"User has reached the maximum concurrent bot limit ({user_limit})."
            )
        logger.info(f"User {user_id} is under bot limit ({current_bot_count}/{user_limit}). Proceeding to start bot service...")

    except HTTPException as http_exc:
         raise http_exc # Re-raise known HTTP exceptions
    except Exception as e:
         logger.error(f"Error during bot limit check for user {user_id}: {e}", exc_info=True)
         # Ensure a generic 500 is raised if not already an HTTPException
         if not isinstance(e, HTTPException):
             raise HTTPException(status_code=500, detail="Failed to verify bot limit due to an unexpected error.")
         raise # Re-raise if it was already an HTTPException from deeper
    # === END: Bot Limit Check ===

    connection_id = str(uuid.uuid4()) # This remains a good unique ID for the session/connection
    service_name = f"vexa-bot-svc-{meeting_id}-{connection_id[:8]}" # Create a unique service name

    if not bot_name: # Default bot name if not provided
        bot_name = f"VexaBot-{connection_id[:6]}"
    
    logger.info(f"Preparing to start bot service '{service_name}' with connectionId: {connection_id}")

    bot_config_data = {
        "meeting_id": meeting_id,
        "platform": platform,
        "meetingUrl": meeting_url,
        "botName": bot_name,
        "token": user_token,
        "nativeMeetingId": native_meeting_id,
        "connectionId": connection_id, # Bot needs this to identify its session
        "language": language,
        "task": task,
        "redisUrl": REDIS_URL,
        "automaticLeave": { # Example, ensure your bot uses this
            "waitingRoomTimeout": 300000,
            "noOneJoinedTimeout": 300000,
            "everyoneLeftTimeout": 300000
        }
    }
    cleaned_config_data = {k: v for k, v in bot_config_data.items() if v is not None}
    bot_config_json = json.dumps(cleaned_config_data)

    logger.debug(f"Bot service '{service_name}' config: {bot_config_json}")

    device_type_env = DEVICE_TYPE
    whisper_live_url = os.getenv('WHISPER_LIVE_CPU_URL', 'ws://whisperlive-cpu:9092') # Default to CPU
    if device_type_env == 'cuda':
        whisper_live_url = os.getenv('WHISPER_LIVE_GPU_URL', 'ws://whisperlive:9090')

    logger.debug(f"Service '{service_name}' using WhisperLive URL: {whisper_live_url} (derived from DEVICE_TYPE: {device_type_env})")

    environment_vars = [
        f"BOT_CONFIG={bot_config_json}",
        f"WHISPER_LIVE_URL={whisper_live_url}",
        f"LOG_LEVEL={os.getenv('LOG_LEVEL', 'INFO').upper()}",
        f"CONNECTION_ID={connection_id}", # Pass connection_id explicitly if bot needs it this way
    ]

    service_labels = {
        "vexa.user_id": str(user_id),
        "vexa.meeting_id": str(meeting_id),
        "vexa.connection_id": connection_id, # Useful for identifying the service later
        "vexa.bot_service": "true"
    }

    try:
        logger.info(f"Attempting to create bot service '{service_name}' (Image: {BOT_IMAGE_NAME}) on network '{DOCKER_NETWORK}'.")

        # Define ContainerSpec for the task
        container_spec = ContainerSpec(
            image=BOT_IMAGE_NAME,
            env=environment_vars,
            labels=service_labels,
            # Add mounts if vexa-bot needs any specific volumes (e.g. for logs, though usually stdout/stderr is preferred)
            # mounts=[Mount(target="/path/in/container", source="named_volume_or_host_path", type="volume_or_bind")]
        )
        
        # Define RestartPolicy for the task
        restart_policy = RestartPolicy(
            condition="on-failure", # or 'any', 'none'
            delay=5,       # 5 seconds
            max_attempts=3,
            window=120      # 2 minutes
        )

        # Define TaskTemplate
        task_template = TaskTemplate(
            container_spec=container_spec,
            restart_policy=restart_policy
            # Add resource constraints if needed for vexa-bot, e.g.
            # resources={'Limits': {'MemoryBytes': 512 * 1024 * 1024}, 'Reservations': {'MemoryBytes': 128 * 1024 * 1024}}
        )

        # Define Network Attachment manually as a dictionary due to broken SDK in image
        # network_attachment = NetworkAttachment(
        #      network=DOCKER_NETWORK, 
        #      aliases=[service_name]
        # )
        network_attachment_dict = {
            "Target": DOCKER_NETWORK,
            "Aliases": [service_name]
        }
        
        # Create the service
        service = client.services.create(
            name=service_name,
            task_template=task_template,
            mode=ServiceMode(mode='replicated', replicas=1), # Each bot is a single replica service
            networks=[network_attachment_dict], # Use the manually created dict
            labels=service_labels, # Labels on the service itself
            endpoint_spec=None # Bots typically don't expose ports, they connect out
        )

        logger.info(f"Successfully created Swarm service '{service.name}' with ID: {service.id} for meeting: {meeting_id}, connection_id: {connection_id}")
        
        # Record session start in DB (ensure this function is robust)
        try:
            # Make sure this is awaited if it's an async function
            await _record_session_start(meeting_id, connection_id) 
        except Exception as db_err:
            logger.error(f"Failed to record session start for service {service.id} / connection {connection_id}: {db_err}", exc_info=True)
            # Decide if service creation should be rolled back if DB fails. For now, logging error.
            # Could raise an exception here to indicate partial failure.

        return service.id, connection_id

    except APIError as e:
        logger.error(f"Docker API error creating service '{service_name}': {e}", exc_info=True)
        # Attempt to clean up if service object exists but ID was not returned or error occurred mid-creation
        # This is complex as the service might or might not have been partially created.
        # For now, relying on subsequent stop calls if something goes very wrong.
    except Exception as e:
        logger.error(f"Unexpected error starting bot service '{service_name}': {e}", exc_info=True)

    return None, None # Explicitly return None, None on failure

def stop_bot_container(service_id_or_name: str) -> bool: # Parameter changed from container_id
    """Stops and removes a vexa-bot Swarm service using its ID or name."""
    client = None
    try:
        client = get_docker_client()
    except DockerNotFound: # Or a broader exception if get_docker_client can raise others
        logger.error(f"Cannot stop service {service_id_or_name}, Docker client not available.")
        return False

    if not client: # Should be caught by exception, but defensive check
        logger.error(f"Cannot stop service {service_id_or_name}, Docker client is None after get_docker_client call.")
        return False

    try:
        logger.info(f"Attempting to find and remove Swarm service '{service_id_or_name}'...")
        service_to_remove = client.services.get(service_id_or_name)
        
        # Get associated connection_id if needed for logging or other cleanup
        connection_id = service_to_remove.attrs.get('Spec', {}).get('Labels', {}).get('vexa.connection_id', 'N/A')
        meeting_id = service_to_remove.attrs.get('Spec', {}).get('Labels', {}).get('vexa.meeting_id', 'N/A')

        service_to_remove.remove()
        logger.info(f"Successfully removed Swarm service '{service_id_or_name}' (Meeting: {meeting_id}, Connection: {connection_id}).")
        
        # Add any additional cleanup related to this bot session if needed, e.g., DB update
        # Example: await _record_session_stop(connection_id)
        
        return True # Corrected indentation
        
    except DockerNotFound:
        logger.warning(f"Swarm service '{service_id_or_name}' not found. Assuming already removed or never existed.")
        return True # Consider it a success if it's not there
    except APIError as e:
        logger.error(f"Docker API error removing service '{service_id_or_name}': {e}", exc_info=True)
        return False
    except Exception as e:
        logger.error(f"Unexpected error stopping/removing service '{service_id_or_name}': {e}", exc_info=True)
        return False 

# --- ADDED: Get Running Bot Status --- 
# Make the function async
async def get_running_bots_status(user_id: int) -> List[Dict[str, Any]]:
    """Gets status of RUNNING bot services for a user using labels, including DB lookup for meeting details."""
    client = None
    try:
        client = get_docker_client()
    except DockerNotFound:
        logger.error("[Bot Status] Cannot get status, Docker client not available.")
        return []
        
    if not client: # Should be caught by exception
        logger.error("[Bot Status] Docker client is None after get_docker_client call.")
        return [] 
        
    bots_status = []
    try:
        # List services labeled for the user
        service_label_filter = f"vexa.user_id={user_id}"
        logger.debug(f"[Bot Status] Querying Swarm services with label filter: '{service_label_filter}'")
        user_bot_services = client.services.list(filters={"label": service_label_filter})
        
        logger.info(f"[Bot Status] Found {len(user_bot_services)} Swarm services potentially for user {user_id}")

        # For each service, get more details and associated task status
        async with async_session_local() as db_session:
            for service in user_bot_services:
                service_attrs = service.attrs # Full service attributes
                service_spec = service_attrs.get('Spec', {})
                service_name = service_spec.get('Name', 'N/A')
                service_id = service.id
                service_labels = service_spec.get('Labels', {})
                
                # Extract meeting_id and connection_id from service labels
                meeting_id_str = service_labels.get('vexa.meeting_id')
                connection_id = service_labels.get('vexa.connection_id')
                
                created_at_timestamp = service_attrs.get('CreatedAt') 
                created_at_iso = None
                if created_at_timestamp:
                    try:
                        if '.' in created_at_timestamp and len(created_at_timestamp.split('.')[1]) > 7:
                            created_at_timestamp = created_at_timestamp[:created_at_timestamp.find('.')+7] + "Z"
                        created_at_iso = datetime.fromisoformat(created_at_timestamp.replace('Z', '+00:00')).isoformat()
                    except ValueError as ve:
                        logger.warning(f"Could not parse service CreatedAt timestamp '{created_at_timestamp}': {ve}")

                task_status_str = "unknown"
                tasks = client.tasks.list(filters={"service": service.id, "desired-state": "running"})
                if tasks: 
                    task = tasks[0] 
                    task_state = task.attrs.get('Status', {}).get('State', 'unknown')
                    task_message = task.attrs.get('Status', {}).get('Message', '')
                    task_err = task.attrs.get('Status', {}).get('Err')
                    task_status_str = f"{task_state}"
                    if task_message and task_message != "started": task_status_str += f" ({task_message})"
                    if task_err: task_status_str += f" Error: {task_err}"
                else: 
                    tasks_all_states = client.tasks.list(filters={"service": service.id})
                    if tasks_all_states:
                        task = tasks_all_states[0]
                        task_state = task.attrs.get('Status', {}).get('State', 'unknown')
                        task_status_str = f"Task state: {task_state}" 
                    else:
                        task_status_str = "No tasks found for service"

                platform_db = None
                native_meeting_id_db = None
                meeting_id_int = None # Initialize before try
                if meeting_id_str:
                    try:
                        meeting_id_int = int(meeting_id_str)
                        # Nested try for the DB operation, only if meeting_id_int is valid
                try:
                    meeting = await db_session.get(Meeting, meeting_id_int)
                    if meeting:
                                platform_db = meeting.platform
                                native_meeting_id_db = meeting.platform_specific_id
                    else:
                                logger.warning(f"[Bot Status] No meeting found in DB for ID {meeting_id_int} from service '{service_name}'")
                        except Exception as db_err: # Handles errors from db_session.get or related logic
                            logger.error(f"[Bot Status] DB error fetching meeting {meeting_id_int} for service '{service_name}': {db_err}", exc_info=True)
                    except ValueError: # Handles errors from int(meeting_id_str)
                        logger.warning(f"[Bot Status] Could not parse meeting_id '{meeting_id_str}' to int for DB lookup (service: {service_name}).")
                
                # This append MUST be inside the 'for service in user_bot_services:' loop
            bots_status.append({
                    "service_id": service_id,
                    "service_name": service_name,
                    "connection_id": connection_id,
                    "meeting_id": meeting_id_str, 
                    "platform": platform_db, 
                    "native_meeting_id": native_meeting_id_db, 
                    "status": task_status_str, 
                    "created_at": created_at_iso, 
                    "labels": service_labels
                })
            # End of 'for service' loop
        # End of 'async with' block
            
    except APIError as api_err:
        logger.error(f"[Bot Status] Docker API error listing services/tasks for user {user_id}: {api_err}", exc_info=True)
        return [] # Return empty on error
    except Exception as e:
        logger.error(f"[Bot Status] Unexpected error listing bot services for user {user_id}: {e}", exc_info=True)
        return []
            
    return bots_status
# --- END: Get Running Bot Status --- 