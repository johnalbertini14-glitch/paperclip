"""
Outlook webhook routes for handling Microsoft Graph change notifications.
"""

import hashlib
import hmac
import json
import logging
from datetime import datetime
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, Header
from fastapi.responses import JSONResponse

from backend.core.config import settings
from backend.core.database import get_db
from backend.core.models import EmailEvent, Integration
from backend.core.services.email_service import EmailService
from backend.core.services.outlook_service import OutlookService
from sqlalchemy.orm import Session

logger = logging.getLogger(__name__)

router = APIRouter()

# Webhook secret for validation
OUTLOOK_WEBHOOK_SECRET = settings.OUTLOOK_WEBHOOK_SECRET


def verify_webhook_signature(
    request: Request,
    validation_token: Optional[str] = Header(None, alias="Validation-Token")
) -> Optional[str]:
    """
    Verify webhook signature for subscription validation.
    
    Args:
        request: FastAPI request
        validation_token: Validation token from header
        
    Returns:
        Validation token if present, None otherwise
    """
    if validation_token:
        # Return validation token for subscription verification
        return validation_token
    return None


@router.get("/outlook")
async def handle_webhook_validation(
    validation_token: Optional[str] = Depends(verify_webhook_signature)
):
    """
    Handle webhook validation request from Microsoft Graph.
    
    Microsoft Graph sends a GET request with Validation-Token header
    when creating or updating a subscription.
    """
    if validation_token:
        # Return validation token in plain text
        from fastapi.responses import PlainTextResponse
        return PlainTextResponse(content=validation_token)
    
    raise HTTPException(
        status_code=400,
        detail="Missing validation token"
    )


@router.post("/outlook")
async def handle_webhook_notification(
    request: Request,
    client_state: Optional[str] = Header(None, alias="Client-State"),
    db: Session = Depends(get_db)
):
    """
    Handle webhook notification from Microsoft Graph.
    
    Microsoft Graph sends a POST request with change notifications
    when subscribed events occur.
    """
    try:
        # Get request body
        body = await request.body()
        body_str = body.decode("utf-8")
        
        # Parse notification
        notification = json.loads(body_str)
        
        # Verify client state
        if not client_state:
            logger.warning("Missing client state in webhook notification")
            raise HTTPException(
                status_code=401,
                detail="Missing client state"
            )
        
        # Extract workspace ID from client state
        # FIX: Add HMAC validation for client state
        try:
            # Verify HMAC signature
            parts = client_state.split(":")
            if len(parts) != 3:
                raise HTTPException(
                    status_code=401,
                    detail="Invalid client state format"
                )
            
            workspace_id, timestamp, received_signature = parts
            
            # Verify signature
            data = f"{workspace_id}:{timestamp}"
            expected_signature = hmac.new(
                OUTLOOK_WEBHOOK_SECRET.encode(),
                data.encode(),
                hashlib.sha256
            ).hexdigest()
            
            if not hmac.compare_digest(received_signature, expected_signature):
                raise HTTPException(
                    status_code=401,
                    detail="Invalid client state signature"
                )
            
            # Check timestamp (allow 5 minute drift)
            if abs(int(timestamp) - int(datetime.utcnow().timestamp())) > 300:
                raise HTTPException(
                    status_code=401,
                    detail="Expired client state"
                )
            
        except (ValueError, TypeError) as e:
            logger.error(f"Error parsing client state: {e}")
            raise HTTPException(
                status_code=401,
                detail="Invalid client state"
            )
        
        # Get integration for this workspace
        integration = db.query(Integration).filter(
            Integration.workspace_id == workspace_id,
            Integration.provider == "outlook"
        ).first()
        
        if not integration:
            logger.error(f"No Outlook integration found for workspace {workspace_id}")
            raise HTTPException(
                status_code=404,
                detail="Integration not found"
            )
        
        # Process notifications
        for notification_item in notification.get("value", []):
            await process_notification(notification_item, integration, db)
        
        # Return JSON response with 202 status
        return JSONResponse(
            content={"status": "Notification processed"},
            status_code=202
        )
        
    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in webhook notification: {e}")
        raise HTTPException(
            status_code=400,
            detail="Invalid JSON payload"
        )
    except Exception as e:
        logger.error(f"Error processing webhook notification: {e}")
        raise HTTPException(
            status_code=500,
            detail="Internal server error"
        )


async def process_notification(
    notification_item: Dict,
    integration: Integration,
    db: Session
):
    """
    Process a single notification item.
    
    Args:
        notification_item: Notification data from Graph API
        integration: Integration object
        db: Database session
    """
    try:
        # Extract resource data
        resource_data = notification_item.get("resourceData", {})
        resource_id = resource_data.get("id")
        resource_url = notification_item.get("resource")
        
        if not resource_id or not resource_url:
            logger.warning("Missing resource data in notification")
            return
        
        # Get email details from Graph API
        outlook_service = OutlookService()
        access_token = await outlook_service.get_valid_access_token(integration)
        
        if not access_token:
            logger.error(f"No valid access token for integration {integration.id}")
            return
        
        # Fetch email details
        email_data = await outlook_service.get_email_details(
            access_token,
            resource_id
        )
        
        if not email_data:
            logger.warning(f"Could not fetch email details for {resource_id}")
            return
        
        # Create email event
        email_event = EmailEvent(
            integration_id=integration.id,
            event_type="email_received",
            event_data=email_data,
            processed=False,
            created_at=datetime.utcnow()
        )
        
        db.add(email_event)
        db.commit()
        
        logger.info(f"Created email event for message {resource_id}")
        
        # Trigger email processing
        email_service = EmailService()
        await email_service.process_email_event(email_event, db)
        
    except Exception as e:
        logger.error(f"Error processing notification item: {e}")
        # Don't raise exception to avoid breaking other notifications