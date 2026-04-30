"""
Input validation models for PageIndex adapter (REVA-249 security fixes).

Provides Pydantic models for config, query parameters, and document metadata.
"""

from pydantic import BaseModel, Field, field_validator, ConfigDict
from typing import Optional
from enum import Enum


class QueryMethod(str, Enum):
    """Query method options."""
    STRUCTURE_AWARE = "structure_aware"
    SEMANTIC_SEARCH = "semantic_search"
    HIERARCHY_TRAVERSAL = "hierarchy_traversal"


class PageIndexConfig(BaseModel):
    """PageIndex adapter configuration with validation."""

    model_config = ConfigDict(use_enum_values=True)

    vault_path: str = Field(
        default="~/Albertini Brain/",
        description="Path to document vault"
    )
    hierarchy_depth_limit: int = Field(
        default=10,
        ge=1,
        le=100,
        description="Maximum depth for hierarchy traversal"
    )
    mcp_server_enabled: bool = Field(
        default=True,
        description="Enable MCP server integration"
    )
    mcp_server_port: int = Field(
        default=8001,
        ge=1024,
        le=65535,
        description="MCP server port (if enabled)"
    )
    max_document_size_bytes: int = Field(
        default=10485760,  # 10MB
        ge=1024,
        description="Maximum document size to process"
    )


class QueryRequest(BaseModel):
    """Query request validation (REVA-249: input validation)."""

    namespace: str = Field(
        min_length=1,
        max_length=255,
        description="Document namespace/ID"
    )
    query: str = Field(
        min_length=1,
        max_length=1000,
        description="Search query"
    )
    method: QueryMethod = Field(
        default=QueryMethod.STRUCTURE_AWARE,
        description="Query method"
    )
    limit: int = Field(
        default=10,
        ge=1,
        le=100,
        description="Maximum results to return"
    )

    @field_validator("query")
    @classmethod
    def validate_query_no_injection(cls, v):
        """Validate query doesn't contain suspicious patterns (REVA-249)."""
        # Prevent ReDoS-like patterns: consecutive wildcards/special chars
        dangerous_patterns = ["***", "$where", "eval", "exec"]
        v_lower = v.lower()
        for pattern in dangerous_patterns:
            if pattern in v_lower:
                raise ValueError(f"Query contains suspicious pattern: {pattern}")
        return v


class DocumentMetadata(BaseModel):
    """Document metadata validation."""

    model_config = ConfigDict(use_enum_values=True)

    document_id: str = Field(
        min_length=1,
        max_length=500,
        description="Document identifier"
    )
    path: Optional[str] = Field(
        default=None,
        max_length=500,
        description="File path in vault"
    )
    workspace_id: Optional[str] = Field(
        default=None,
        description="Workspace scoping (REVA-249 security)"
    )
    content_hash: Optional[str] = Field(
        default=None,
        description="Document content hash"
    )
    created_at: Optional[str] = Field(
        default=None,
        description="Document creation timestamp"
    )
