"""
Outlook integration routes for OAuth flow and management.
"""

import base64
import json
import logging
from datetime import datetime
from typing import Dict, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from backend.core.config import settings
from backend.core.database import get_db
from backend.core.models import Integration, User
from backend.core.services.outlook_service import OutlookService

logger = logging.getLogger(__name__)

router = APIRouter()
outlook_service = OutlookService()


@router.get("/oauth/authorize")
async def authorize_outlook(
    request: Request,
    user_id: str = Query(...),
    workspace_id: str = Query(...),
    redirect_uri: str = Query(...),
    db: Session = Depends(get_db)
):
    """
    Start OAuth 2.0 authorization flow for Outlook.
    
    Args:
        user_id: User ID
        workspace_id: Workspace ID
        redirect_uri: OAuth redirect URI
        db: Database session
        
    Returns:
        Redirect to Microsoft Graph authorization URL
    """
    try:
        # Verify user exists
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        
        # Build authorization URL
        auth_url = outlook_service.build_authorization_url(
            user_id=user_id,
            workspace_id=workspace_id,
            redirect_uri=redirect_uri
        )
        
        logger.info(f"Redirecting to Outlook authorization URL for user {user_id}")
        return RedirectResponse(url=auth_url)
        
    except Exception as e:
        logger.error(f"Error starting Outlook OAuth flow: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")


@router.get("/oauth/callback")
async def outlook_oauth_callback(
    request: Request,
    code: str = Query(None),
    error: str = Query(None),
    error_description: str = Query(None),
    state: str = Query(None),
    db: Session = Depends(get_db)
):
    """
    Handle OAuth 2.0 callback from Microsoft Graph.
    
    Args:
        code: Authorization code (if successful)
        error: Error code (if failed)
        error_description: Error description (if failed)
        state: OAuth state parameter
        db: Database session
        
    Returns:
        Redirect to frontend with success/error
    """
    try:
        # Check for OAuth error
        if error:
            logger.error(f"Outlook OAuth error: {error} - {error_description}")
            # Redirect to frontend error page
            frontend_error_url = f"{settings.FRONTEND_URL}/integrations/outlook/error"
            error_params = f"?error={error}&description={error_description}"
            return RedirectResponse(url=frontend_error_url + error_params)
        
        if not code:
            raise HTTPException(status_code=400, detail="Missing authorization code")
        
        if not state:
            raise HTTPException(status_code=400, detail="Missing state parameter")
        
        # Decode state parameter
        try:
            state_json = base64.urlsafe_b64decode(state.encode()).decode()
            state_data = json.loads(state_json)
            
            user_id = state_data.get("user_id")
            workspace_id = state_data.get("workspace_id")
            redirect_uri = state_data.get("redirect_uri")
            
            if not all([user_id, workspace_id, redirect_uri]):
                raise ValueError("Invalid state data")
                
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as e:
            logger.error(f"Error decoding state parameter: {e}")
            raise HTTPException(status_code=400, detail="Invalid state parameter")
        
        # Exchange code for tokens
        tokens = await outlook_service.exchange_code_for_tokens(code, redirect_uri)
        
        # Get user info from Graph API
        user_info = await outlook_service.get_user_info(tokens["access_token"])
        
        # Store integration
        integration = outlook_service.store_integration_credentials(
            user_id=user_id,
            workspace_id=workspace_id,
            tokens=tokens,
            user_info=user_info
        )
        
        logger.info(f"Outlook integration created for user {user_id}: {integration.id}")
        
        # Redirect to frontend success page
        frontend_success_url = f"{settings.FRONTEND_URL}/integrations/outlook/success"
        success_params = f"?integration_id={integration.id}&user_email={user_info.get('userPrincipalName', '')}"
        return RedirectResponse(url=frontend_success_url + success_params)
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error processing Outlook OAuth callback: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")


@router.post("/subscriptions")
async def create_outlook_subscription(
    request: Request,
    user_id: str,
    workspace_id: str,
    db: Session = Depends(get_db)
) -> Dict:
    """
    Create Outlook webhook subscription.
    
    Args:
        user_id: User ID
        workspace_id: Workspace ID
        db: Database session
        
    Returns:
        Subscription creation response
    """
    try:
        # Get integration
        integration = db.query(Integration).filter(
            Integration.user_id == user_id,
            Integration.workspace_id == workspace_id,
            Integration.provider == "outlook"
        ).first()
        
        if not integration:
            raise HTTPException(status_code=404, detail="Outlook integration not found")
        
        # Create subscription
        subscription = await outlook_service.create_webhook_subscription(integration)
        
        return {
            "success": True,
            "subscription_id": subscription.id,
            "expires_at": subscription.expires_at.isoformat(),
            "message": "Outlook webhook subscription created successfully"
        }
        
    except Exception as e:
        logger.error(f"Error creating Outlook subscription: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/subscriptions/{subscription_id}")
async def delete_outlook_subscription(
    subscription_id: str,
    user_id: str,
    workspace_id: str,
    db: Session = Depends(get_db)
) -> Dict:
    """
    Delete Outlook webhook subscription.
    
    Args:
        subscription_id: Subscription ID
        user_id: User ID
        workspace_id: Workspace ID
        db: Database session
        
    Returns:
        Deletion response
    """
    try:
        # Get integration
        integration = db.query(Integration).filter(
            Integration.user_id == user_id,
            Integration.workspace_id == workspace_id,
            Integration.provider == "outlook"
        ).first()
        
        if not integration:
            raise HTTPException(status_code=404, detail="Outlook integration not found")
        
        # Delete subscription
        success = await outlook_service.delete_webhook_subscription(
            integration,
            subscription_id
        )
        
        if success:
            return {
                "success": True,
                "message": "Outlook webhook subscription deleted successfully"
            }
        else:
            raise HTTPException(
                status_code=500,
                detail="Failed to delete subscription"
            )
        
    except Exception as e:
        logger.error(f"Error deleting Outlook subscription: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/status")
async def get_outlook_status(
    user_id: str,
    workspace_id: str,
    db: Session = Depends(get_db)
) -> Dict:
    """
    Get Outlook integration status.
    
    Args:
        user_id: User ID
        workspace_id: Workspace ID
        db: Database session
        
    Returns:
        Integration status
    """
    try:
        # Get integration
        integration = db.query(Integration).filter(
            Integration.user_id == user_id,
            Integration.workspace_id == workspace_id,
            Integration.provider == "outlook"
        ).first()
        
        if not integration:
            raise HTTPException(status_code=404, detail="Outlook integration not found")
        
        # Check if tokens are valid
        is_valid = await outlook_service.validate_integration(integration)
        
        # Get active subscriptions
        subscriptions = db.query(Subscription).filter(
            Subscription.integration_id == integration.id,
            Subscription.active == True
        ).all()
        
        return {
            "connected": True,
            "valid": is_valid,
            "user_email": integration.metadata.get("user_principal_name"),
            "connected_at": integration.created_at.isoformat(),
            "subscriptions": [
                {
                    "id": sub.id,
                    "expires_at": sub.expires_at.isoformat(),
                    "created_at": sub.created_at.isoformat()
                }
                for sub in subscriptions
            ]
        }
        
    except Exception as e:
        logger.error(f"Error getting Outlook status: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/send-test-email")
async def send_test_email(
    user_id: str,
    workspace_id: str,
    to_email: str,
    db: Session = Depends(get_db)
) -> Dict:
    """
    Send test email via Outlook.
    
    Args:
        user_id: User ID
        workspace_id: Workspace ID
        to_email: Recipient email address
        db: Database session
        
    Returns:
        Send response
    """
    try:
        # Get integration
        integration = db.query(Integration).filter(
            Integration.user_id == user_id,
            Integration.workspace_id == workspace_id,
            Integration.provider == "outlook"
        ).first()
        
        if not integration:
            raise HTTPException(status_code=404, detail="Outlook integration not found")
        
        # Send test email
        result = await outlook_service.send_test_email(integration, to_email)
        
        return {
            "success": True,
            "message": "Test email sent successfully",
            "result": result
        }
        
    except Exception as e:
        logger.error(f"Error sending test email: {e}")
        raise HTTPException(status_code=500, detail=str(e))