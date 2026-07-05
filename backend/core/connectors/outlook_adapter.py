"""
Outlook/Microsoft 365 connector adapter.

Handles OAuth 2.0 authentication, mail sending, and subscription management
with Microsoft Graph API.
"""

import base64
import hashlib
import hmac
import json
import logging
import time
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlencode, quote

import httpx
from pydantic import BaseModel, Field

from backend.core.config import settings
from backend.core.database import SessionLocal
from backend.core.models import Integration, User

logger = logging.getLogger(__name__)

# Graph API constants
GRAPH_AUTH_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
GRAPH_TOKEN_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
GRAPH_API_URL = "https://graph.microsoft.com/v1.0"
GRAPH_INBOX_FOLDER_URL = f"{GRAPH_API_URL}/me/mailFolders('inbox')/messages"
GRAPH_SEND_URL = f"{GRAPH_API_URL}/me/sendMail"
GRAPH_SUBSCRIPTION_URL = f"{GRAPH_API_URL}/subscriptions"

# Webhook constants
OUTLOOK_WEBHOOK_SECRET = settings.OUTLOOK_WEBHOOK_SECRET


class OutlookOAuthState(BaseModel):
    """OAuth state for Outlook authentication."""
    
    user_id: str
    workspace_id: str
    redirect_uri: str
    timestamp: float = Field(default_factory=time.time)


class OutlookAdapter:
    """Adapter for Microsoft 365/Outlook integration."""
    
    def __init__(self):
        self.client = httpx.AsyncClient(timeout=30.0)
        
    async def close(self):
        """Close HTTP client."""
        await self.client.aclose()
        
    def build_authorization_url(
        self,
        user_id: str,
        workspace_id: str,
        redirect_uri: str,
        scopes: List[str] = None
    ) -> str:
        """
        Build OAuth 2.0 authorization URL for Microsoft Graph.
        
        Args:
            user_id: User ID
            workspace_id: Workspace ID
            redirect_uri: OAuth redirect URI
            scopes: List of scopes (defaults to mail read/write/send)
            
        Returns:
            Authorization URL
        """
        if scopes is None:
            scopes = [
                "User.Read",
                "Mail.Read",
                "Mail.ReadWrite",
                "Mail.Send",
                "MailboxSettings.Read",
                "offline_access"
            ]
        
        # Create state parameter
        state_data = OutlookOAuthState(
            user_id=user_id,
            workspace_id=workspace_id,
            redirect_uri=redirect_uri
        )
        state_json = state_data.model_dump_json()
        state_encoded = base64.urlsafe_b64encode(state_json.encode()).decode()
        
        params = {
            "client_id": settings.MICROSOFT_CLIENT_ID,
            "response_type": "code",
            "redirect_uri": redirect_uri,
            "scope": " ".join(scopes),
            "state": state_encoded,
            "response_mode": "query"
        }
        
        return f"{GRAPH_AUTH_URL}?{urlencode(params, quote_via=quote)}"
    
    async def exchange_code_for_tokens(self, code: str, redirect_uri: str) -> Dict[str, Any]:
        """
        Exchange authorization code for access and refresh tokens.
        
        Args:
            code: Authorization code
            redirect_uri: OAuth redirect URI
            
        Returns:
            Token response from Graph API
        """
        data = {
            "client_id": settings.MICROSOFT_CLIENT_ID,
            "client_secret": settings.MICROSOFT_CLIENT_SECRET,
            "code": code,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code"
        }
        
        response = await self.client.post(GRAPH_TOKEN_URL, data=data)
        response.raise_for_status()
        return response.json()
    
    async def refresh_tokens(self, refresh_token: str) -> Dict[str, Any]:
        """
        Refresh access token using refresh token.
        
        Args:
            refresh_token: Refresh token
            
        Returns:
            New token response from Graph API
        """
        data = {
            "client_id": settings.MICROSOFT_CLIENT_ID,
            "client_secret": settings.MICROSOFT_CLIENT_SECRET,
            "refresh_token": refresh_token,
            "grant_type": "refresh_token"
        }
        
        response = await self.client.post(GRAPH_TOKEN_URL, data=data)
        response.raise_for_status()
        return response.json()
    
    async def get_user_info(self, access_token: str) -> Dict[str, Any]:
        """
        Get user information from Graph API.
        
        Args:
            access_token: Access token
            
        Returns:
            User information
        """
        headers = {"Authorization": f"Bearer {access_token}"}
        response = await self.client.get(f"{GRAPH_API_URL}/me", headers=headers)
        response.raise_for_status()
        return response.json()
    
    async def send_email(
        self,
        access_token: str,
        to: List[str],
        subject: str,
        body: str,
        body_type: str = "HTML",
        cc: List[str] = None,
        bcc: List[str] = None,
        attachments: List[Dict] = None
    ) -> Dict[str, Any]:
        """
        Send email via Microsoft Graph.
        
        Args:
            access_token: Access token
            to: List of recipient email addresses
            subject: Email subject
            body: Email body
            body_type: "HTML" or "Text"
            cc: List of CC email addresses
            bcc: List of BCC email addresses
            attachments: List of attachment dictionaries
            
        Returns:
            Send response
        """
        message = {
            "message": {
                "subject": subject,
                "body": {
                    "contentType": body_type,
                    "content": body
                },
                "toRecipients": [{"emailAddress": {"address": email}} for email in to]
            },
            "saveToSentItems": True
        }
        
        if cc:
            message["message"]["ccRecipients"] = [
                {"emailAddress": {"address": email}} for email in cc
            ]
        
        if bcc:
            message["message"]["bccRecipients"] = [
                {"emailAddress": {"address": email}} for email in bcc
            ]
        
        if attachments:
            message["message"]["attachments"] = attachments
        
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json"
        }
        
        response = await self.client.post(GRAPH_SEND_URL, json=message, headers=headers)
        response.raise_for_status()
        
        if response.status_code == 202:
            return {"status": "accepted", "message": "Email sent successfully"}
        return response.json()
    
    async def create_subscription(
        self,
        access_token: str,
        webhook_url: str,
        client_state: str,
        expiration_days: int = 2
    ) -> Dict[str, Any]:
        """
        Create a subscription for inbox notifications.
        
        Args:
            access_token: Access token
            webhook_url: Webhook URL to receive notifications
            client_state: Client state for webhook validation
            expiration_days: Subscription expiration in days
            
        Returns:
            Subscription response
        """
        # FIX: Use relative path instead of full URL for resource
        resource = "me/mailFolders('inbox')/messages"
        
        expiration_time = (datetime.utcnow() + timedelta(days=expiration_days)).isoformat() + "Z"
        
        subscription = {
            "changeType": "created",
            "notificationUrl": webhook_url,
            "resource": resource,
            "expirationDateTime": expiration_time,
            "clientState": client_state,
            "includeResourceData": False
        }
        
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json"
        }
        
        response = await self.client.post(
            GRAPH_SUBSCRIPTION_URL,
            json=subscription,
            headers=headers
        )
        response.raise_for_status()
        return response.json()
    
    async def renew_subscription(
        self,
        access_token: str,
        subscription_id: str,
        expiration_days: int = 2
    ) -> Dict[str, Any]:
        """
        Renew a subscription before it expires.
        
        Args:
            access_token: Access token
            subscription_id: Subscription ID
            expiration_days: New expiration in days
            
        Returns:
            Renewal response
        """
        expiration_time = (datetime.utcnow() + timedelta(days=expiration_days)).isoformat() + "Z"
        
        update = {
            "expirationDateTime": expiration_time
        }
        
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json"
        }
        
        response = await self.client.patch(
            f"{GRAPH_SUBSCRIPTION_URL}/{subscription_id}",
            json=update,
            headers=headers
        )
        response.raise_for_status()
        return response.json()
    
    async def delete_subscription(self, access_token: str, subscription_id: str) -> bool:
        """
        Delete a subscription.
        
        Args:
            access_token: Access token
            subscription_id: Subscription ID
            
        Returns:
            True if successful
        """
        headers = {"Authorization": f"Bearer {access_token}"}
        response = await self.client.delete(
            f"{GRAPH_SUBSCRIPTION_URL}/{subscription_id}",
            headers=headers
        )
        return response.status_code == 204
    
    async def get_inbox_messages(
        self,
        access_token: str,
        top: int = 10,
        skip: int = 0,
        filter_query: str = None
    ) -> Dict[str, Any]:
        """
        Get messages from inbox.
        
        Args:
            access_token: Access token
            top: Number of messages to retrieve
            skip: Number of messages to skip
            filter_query: OData filter query
            
        Returns:
            Messages response
        """
        headers = {"Authorization": f"Bearer {access_token}"}
        params = {"$top": top, "$skip": skip}
        
        if filter_query:
            params["$filter"] = filter_query
        
        response = await self.client.get(
            GRAPH_INBOX_FOLDER_URL,
            headers=headers,
            params=params
        )
        response.raise_for_status()
        return response.json()
    
    def generate_client_state(self, workspace_id: str) -> str:
        """
        Generate a signed client state for webhook validation.
        
        Args:
            workspace_id: Workspace ID
            
        Returns:
            Signed client state
        """
        timestamp = str(int(time.time()))
        data = f"{workspace_id}:{timestamp}"
        signature = hmac.new(
            OUTLOOK_WEBHOOK_SECRET.encode(),
            data.encode(),
            hashlib.sha256
        ).hexdigest()
        return f"{data}:{signature}"
    
    def verify_client_state(self, client_state: str, workspace_id: str) -> bool:
        """
        Verify client state signature.
        
        Args:
            client_state: Client state from webhook
            workspace_id: Expected workspace ID
            
        Returns:
            True if valid
        """
        try:
            parts = client_state.split(":")
            if len(parts) != 3:
                return False
            
            received_workspace_id, timestamp, received_signature = parts
            
            if received_workspace_id != workspace_id:
                return False
            
            # Check timestamp (allow 5 minute drift)
            if abs(int(timestamp) - int(time.time())) > 300:
                return False
            
            data = f"{received_workspace_id}:{timestamp}"
            expected_signature = hmac.new(
                OUTLOOK_WEBHOOK_SECRET.encode(),
                data.encode(),
                hashlib.sha256
            ).hexdigest()
            
            return hmac.compare_digest(received_signature, expected_signature)
        except (ValueError, TypeError):
            return False
    
    def store_integration_credentials(
        self,
        user_id: str,
        workspace_id: str,
        tokens: Dict[str, Any]
    ) -> None:
        """
        Store integration credentials in database.
        
        Args:
            user_id: User ID
            workspace_id: Workspace ID
            tokens: Token response from Graph API
        """
        # Validate we're not storing app credentials
        forbidden_keys = {"client_id", "client_secret", "microsoft_client_id", "microsoft_client_secret"}
        for key in forbidden_keys:
            if key in tokens:
                raise ValueError(f"Cannot store app credential '{key}' in user integration")
        
        integration_data = {
            "user_id": user_id,
            "workspace_id": workspace_id,
            "provider": "outlook",
            "access_token": tokens.get("access_token"),
            "refresh_token": tokens.get("refresh_token"),
            "expires_at": datetime.utcnow() + timedelta(seconds=tokens.get("expires_in", 3600)),
            "metadata": {
                "user_principal_name": tokens.get("id_token_claims", {}).get("preferred_username"),
                "scope": tokens.get("scope"),
                "token_type": tokens.get("token_type")
            }
        }
        
        with SessionLocal() as db:
            # Check if integration exists
            integration = db.query(Integration).filter(
                Integration.user_id == user_id,
                Integration.workspace_id == workspace_id,
                Integration.provider == "outlook"
            ).first()
            
            if integration:
                integration.access_token = integration_data["access_token"]
                integration.refresh_token = integration_data["refresh_token"]
                integration.expires_at = integration_data["expires_at"]
                integration.metadata = integration_data["metadata"]
                integration.updated_at = datetime.utcnow()
            else:
                integration = Integration(**integration_data)
                db.add(integration)
            
            db.commit()
    
    def get_integration_credentials(self, user_id: str, workspace_id: str) -> Optional[Integration]:
        """
        Get integration credentials from database.
        
        Args:
            user_id: User ID
            workspace_id: Workspace ID
            
        Returns:
            Integration object or None
        """
        with SessionLocal() as db:
            integration = db.query(Integration).filter(
                Integration.user_id == user_id,
                Integration.workspace_id == workspace_id,
                Integration.provider == "outlook"
            ).first()
            return integration