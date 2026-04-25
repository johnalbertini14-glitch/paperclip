"""PageIndex semantic tree adapter for Paperclip platform."""

from .adapter import (
    PageIndexAdapter,
    QueryMethod,
    SemanticNode,
    SearchResult,
    ADAPTER_CONFIG_SCHEMA
)
from .mcp_server import PageIndexMCPServer, MCP_TOOLS_SCHEMA
from .semantic_tree import SemanticTreeBuilder, SemanticTreeTraversal

__version__ = "0.1.0"
__all__ = [
    "PageIndexAdapter",
    "PageIndexMCPServer",
    "SemanticTreeBuilder",
    "SemanticTreeTraversal",
    "QueryMethod",
    "SemanticNode",
    "SearchResult",
    "ADAPTER_CONFIG_SCHEMA",
    "MCP_TOOLS_SCHEMA"
]
