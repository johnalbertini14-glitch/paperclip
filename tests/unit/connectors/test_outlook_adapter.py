"""
Tests for Outlook adapter.
"""

import base64
import json
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.core.connectors.outlook_adapter import (
    OutlookAdapter,
    OutlookOAuthState,
    GRAPH_AUTH_URL
)


class TestOutlookAdapter:
    """Test suite for OutlookAdapter."""
    
    @pytest.fixture
    def adapter(self):
        """Create OutlookAdapter instance."""
        return OutlookAdapter()
    
    @pytest.fixture
    def mock_settings(self):
        """Mock settings."""
        with patch("backend.core.connectors.outlook_adapter.settings") as mock_settings:
            mock_settings.MICROSOFT_CLIENT_ID = "test-client-id"
            mock_settings.MICROSOFT_CLIENT_SECRET = "test-client-secret"
            mock_settings.OUTLOOK_WEBHOOK_SECRET = "test-webhook-secret"
            yield mock_settings
    
    def test_build_authorization_url(self, adapter, mock_settings):
        """Test building authorization URL."""
        # Test data
        user_id = "user-123"
        workspace_id = "workspace-456"
        redirect_uri = "https://example.com/callback"
        
        # Build URL
        auth_url = adapter.build_authorization_url(
            user_id=user_id,
            workspace_id=workspace_id,
            redirect_uri=redirect_uri
        )
        
        # Verify URL structure
        assert auth_url.startswith(GRAPH_AUTH_URL)
        assert "client_id=test-client-id" in auth_url
        assert f"redirect_uri={redirect_uri}" in auth_url
        assert "response_type=code" in auth_url
        assert "scope=" in auth_url
        assert "state=" in auth_url
        
        # Verify state parameter
        import urllib.parse
        parsed_url = urllib.parse.urlparse(auth_url)
        query_params = urllib.parse.parse_qs(parsed_url.query)
        
        assert "state" in query_params
        state_encoded = query_params["state"][0]
        
        # Decode and verify state
        state_json = base64.urlsafe_b64decode(state_encoded.encode()).decode()
        state_data = json.loads(state_json)
        
        assert state_data["user_id"] == user_id
        assert state_data["workspace_id"] == workspace_id
        assert state_data["redirect_uri"] == redirect_uri
        assert "timestamp" in state_data
        
        # Test with custom scopes
        custom_scopes = ["Mail.Read", "Mail.Send"]
        auth_url_custom = adapter.build_authorization_url(
            user_id=user_id,
            workspace_id=workspace_id,
            redirect_uri=redirect_uri,
            scopes=custom_scopes
        )
        
        assert "Mail.Read" in auth_url_custom
        assert "Mail.Send" in auth_url_custom
    
    @pytest.mark.asyncio
    async def test_exchange_code_for_tokens(self, adapter, mock_settings):
        """Test exchanging code for tokens."""
        # Mock HTTP response
        mock_response = AsyncMock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {
            "access_token": "test-access-token",
            "refresh_token": "test-refresh-token",
            "expires_in": 3600,
            "token_type": "Bearer"
        }
        
        adapter.client.post = AsyncMock(return_value=mock_response)
        
        # Exchange code
        code = "test-auth-code"
        redirect_uri = "https://example.com/callback"
        
        tokens = await adapter.exchange_code_for_tokens(code, redirect_uri)
        
        # Verify request
        adapter.client.post.assert_called_once()
        call_args = adapter.client.post.call_args
        
        assert call_args[0][0] == "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        
        # Verify form data
        form_data = call_args[1]["data"]
        assert form_data["client_id"] == "test-client-id"
        assert form_data["client_secret"] == "test-client-secret"
        assert form_data["code"] == code
        assert form_data["redirect_uri"] == redirect_uri
        assert form_data["grant_type"] == "authorization_code"
        
        # Verify response
        assert tokens["access_token"] == "test-access-token"
        assert tokens["refresh_token"] == "test-refresh-token"
        assert tokens["expires_in"] == 3600
    
    @pytest.mark.asyncio
    async def test_refresh_tokens(self, adapter, mock_settings):
        """Test refreshing tokens."""
        # Mock HTTP response
        mock_response = AsyncMock()
        mock_response.raise_for_status.return_value = None
        mock_response.json.return_value = {
            "access_token": "new-access-token",
            "refresh_token": "new-refresh-token",
            "expires_in": 3600
        }
        
        adapter.client.post = AsyncMock(return_value=mock_response)
        
        # Refresh tokens
        refresh_token = "old-refresh-token"
        tokens = await adapter.refresh_tokens(refresh_token)
        
        # Verify request
        adapter.client.post.assert_called_once()
        call_args = adapter.client.post.call_args
        
        # Verify form data
        form_data = call_args[1]["data"]
        assert form_data["client_id"] == "test-client-id"
        assert form_data["client_secret"] == "test-client-secret"
        assert form_data["refresh_token"] == refresh_token
        assert form_data["grant_type"] == "refresh_token"
        
        # Verify response
        assert tokens["access_token"] == "new-access-token"
        assert tokens["refresh_token"] == "new-refresh-token"
    
    def test_generate_client_state(self, adapter, mock_settings):
        """Test generating client state."""
        workspace_id = "test-workspace"
        client_state = adapter.generate_client_state(workspace_id)
        
        # Verify format
        parts = client_state.split(":")
        assert len(parts) == 3
        
        generated_workspace_id, timestamp, signature = parts
        
        # Verify workspace ID
        assert generated_workspace_id == workspace_id
        
        # Verify timestamp is recent
        assert abs(int(timestamp) - int(time.time())) < 5
        
        # Verify signature can be validated
        assert adapter.verify_client_state(client_state, workspace_id)
    
    def test_verify_client_state_valid(self, adapter, mock_settings):
        """Test verifying valid client state."""
        workspace_id = "test-workspace"
        client_state = adapter.generate_client_state(workspace_id)
        
        # Should be valid
        assert adapter.verify_client_state(client_state, workspace_id)
    
    def test_verify_client_state_invalid_signature(self, adapter, mock_settings):
        """Test verifying client state with invalid signature."""
        workspace_id = "test-workspace"
        timestamp = str(int(time.time()))
        data = f"{workspace_id}:{timestamp}"
        
        # Create invalid signature (wrong secret)
        import hashlib
        import hmac
        invalid_signature = hmac.new(
            b"wrong-secret",
            data.encode(),
            hashlib.sha256
        ).hexdigest()
        
        client_state = f"{data}:{invalid_signature}"
        
        # Should be invalid
        assert not adapter.verify_client_state(client_state, workspace_id)
    
    def test_verify_client_state_expired(self, adapter, mock_settings):
        """Test verifying expired client state."""
        workspace_id = "test-workspace"
        
        # Create expired timestamp (10 minutes ago)
        expired_timestamp = str(int(time.time()) - 600)
        data = f"{workspace_id}:{expired_timestamp}"
        
        import hashlib
        import hmac
        signature = hmac.new(
            b"test-webhook-secret",
            data.encode(),
            hashlib.sha256
        ).hexdigest()
        
        client_state = f"{data}:{signature}"
        
        # Should be invalid (expired)
        assert not adapter.verify_client_state(client_state, workspace_id)
    
    def test_verify_client_state_wrong_workspace(self, adapter, mock_settings):
        """Test verifying client state with wrong workspace ID."""
        workspace_id = "test-workspace"
        client_state = adapter.generate_client_state(workspace_id)
        
        # Different workspace ID should fail
        assert not adapter.verify_client_state(client_state, "different-workspace")
    
    def test_store_integration_credentials_validation(self, adapter):
        """Test that store_integration_credentials validates against app credentials."""
        # Test with app credentials in tokens (should fail)
        tokens_with_app_creds = {
            "access_token": "user-token",
            "client_id": "should-not-store-this"
        }
        
        with pytest.raises(ValueError, match="Cannot store app credential 'client_id' in user integration"):
            adapter.store_integration_credentials(
                user_id="user-123",
                workspace_id="workspace-456",
                tokens=tokens_with_app_creds
            )
    
    @pytest.mark.asyncio
    async def test_close(self, adapter):
        """Test closing HTTP client."""
        adapter.client.aclose = AsyncMock()
        
        await adapter.close()
        
        adapter.client.aclose.assert_called_once()


class TestOutlookOAuthState:
    """Test suite for OutlookOAuthState model."""
    
    def test_model_creation(self):
        """Test creating OAuth state model."""
        state = OutlookOAuthState(
            user_id="user-123",
            workspace_id="workspace-456",
            redirect_uri="https://example.com/callback"
        )
        
        assert state.user_id == "user-123"
        assert state.workspace_id == "workspace-456"
        assert state.redirect_uri == "https://example.com/callback"
        assert isinstance(state.timestamp, float)
        assert state.timestamp > 0
    
    def test_model_dump_json(self):
        """Test serializing model to JSON."""
        state = OutlookOAuthState(
            user_id="user-123",
            workspace_id="workspace-456",
            redirect_uri="https://example.com/callback"
        )
        
        json_str = state.model_dump_json()
        data = json.loads(json_str)
        
        assert data["user_id"] == "user-123"
        assert data["workspace_id"] == "workspace-456"
        assert data["redirect_uri"] == "https://example.com/callback"
        assert "timestamp" in data