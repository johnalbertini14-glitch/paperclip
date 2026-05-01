"""
MCP Server integration for PageIndex adapter.

Exposes semantic tree navigation and querying through MCP protocol
for agent access to document hierarchies.
"""

from typing import Dict, List, Optional, Any
import logging
from pydantic import ValidationError

from .adapter import PageIndexAdapter, QueryMethod, SearchResult
from .validators import QueryRequest

logger = logging.getLogger(__name__)


class PageIndexMCPServer:
    """
    MCP server exposing PageIndex semantic tree functionality.

    Provides tools for agents to:
    - Navigate document hierarchies
    - Query semantic trees
    - Retrieve document sections with context
    """

    def __init__(self, adapter: PageIndexAdapter):
        """Initialize MCP server with PageIndex adapter."""
        self.adapter = adapter
        self.logger = logger

    async def initialize(self) -> None:
        """Initialize MCP server and adapter."""
        await self.adapter.initialize()
        self.logger.info("PageIndex MCP server initialized")

    async def get_semantic_tree(self, namespace: str) -> Optional[Dict[str, Any]]:
        """
        Get semantic tree for namespace.

        Returns:
            Dictionary representation of semantic tree or None if not found
        """
        tree = await self.adapter.get_tree(namespace)
        if not tree:
            return None

        return await self._serialize_tree(tree)

    async def query_tree(
        self,
        namespace: str,
        query: str,
        method: str = "structure_aware",
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """
        Query semantic tree in namespace.

        Args:
            namespace: Document namespace to query
            query: Search query string
            method: Query method (structure_aware, semantic_search, hierarchy_traversal)
            limit: Maximum results to return

        Returns:
            List of search results with hierarchy context
        """
        try:
            validated = QueryRequest(
                namespace=namespace,
                query=query,
                method=method,
                limit=limit
            )
        except ValidationError as e:
            self.logger.warning("Query validation failed: %s", e)
            raise ValueError(f"Invalid query parameters: {e}") from e

        try:
            query_method = QueryMethod(validated.method)
        except ValueError:
            query_method = QueryMethod.STRUCTURE_AWARE

        results = await self.adapter.query(
            namespace=validated.namespace,
            query=validated.query,
            method=query_method,
            limit=validated.limit
        )

        return [await self._serialize_result(r) for r in results]

    async def list_documents(self) -> List[str]:
        """List all available document namespaces."""
        return await self.adapter.list_namespaces()

    async def get_document_section(
        self,
        namespace: str,
        node_id: str,
        include_hierarchy: bool = True
    ) -> Optional[Dict[str, Any]]:
        """
        Get specific document section with optional hierarchy context.

        Args:
            namespace: Document namespace
            node_id: Node ID in semantic tree
            include_hierarchy: Include ancestor nodes in response

        Returns:
            Document section with metadata and hierarchy context
        """
        tree = await self.adapter.get_tree(namespace)
        if not tree:
            self.logger.warning("Namespace not found: %s", namespace)
            return None

        node = self._find_node_by_id(tree, node_id)
        if not node:
            self.logger.warning("Node not found: %s in %s", node_id, namespace)
            return None

        result = {
            "node": await self._serialize_tree(node),
            "metadata": node.metadata
        }

        if include_hierarchy:
            result["ancestry"] = await self._get_node_ancestry(tree, node_id)

        return result

    def _find_node_by_id(self, root, node_id: str) -> Optional[Any]:
        """Find node by ID in semantic tree."""
        if root.id == node_id:
            return root

        for child in root.children:
            found = self._find_node_by_id(child, node_id)
            if found:
                return found

        return None

    async def _get_node_ancestry(
        self, root, node_id: str, path: Optional[List[Dict[str, Any]]] = None
    ) -> List[Dict[str, Any]]:
        """Get ancestry chain for a node."""
        if path is None:
            path = []

        if root.id == node_id:
            return path + [await self._serialize_tree(root)]

        for child in root.children:
            serialized = await self._serialize_tree(root)
            found = await self._get_node_ancestry(child, node_id, path + [serialized])
            if found:
                return found

        return []

    async def _serialize_tree(self, node: Any) -> Dict[str, Any]:
        """Serialize semantic tree node to dictionary."""
        return {
            "id": node.id,
            "title": node.title,
            "level": node.level,
            "path": node.path,
            "children": [
                await self._serialize_tree(child)
                for child in node.children
            ],
            "metadata": node.metadata
        }

    async def _serialize_result(self, result: SearchResult) -> Dict[str, Any]:
        """Serialize search result to dictionary."""
        return {
            "node": await self._serialize_tree(result.node),
            "relevance_score": result.relevance_score,
            "hierarchy_context": result.hierarchy_context,
            "matched_content": result.matched_content
        }


# MCP Tool Schema
MCP_TOOLS_SCHEMA = [
    {
        "name": "get_semantic_tree",
        "description": "Get semantic tree structure for document namespace",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {
                    "type": "string",
                    "description": "Document namespace identifier"
                }
            },
            "required": ["namespace"]
        }
    },
    {
        "name": "query_tree",
        "description": "Query semantic tree for relevant document sections",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {
                    "type": "string",
                    "description": "Document namespace to query"
                },
                "query": {
                    "type": "string",
                    "description": "Search query string"
                },
                "method": {
                    "type": "string",
                    "enum": ["structure_aware", "semantic_search", "hierarchy_traversal"],
                    "default": "structure_aware",
                    "description": "Query method"
                },
                "limit": {
                    "type": "integer",
                    "default": 10,
                    "description": "Maximum results to return"
                }
            },
            "required": ["namespace", "query"]
        }
    },
    {
        "name": "list_documents",
        "description": "List all available document namespaces",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "get_document_section",
        "description": "Get specific document section with hierarchy context",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {
                    "type": "string",
                    "description": "Document namespace"
                },
                "node_id": {
                    "type": "string",
                    "description": "Node ID in semantic tree"
                },
                "include_hierarchy": {
                    "type": "boolean",
                    "default": True,
                    "description": "Include ancestor nodes"
                }
            },
            "required": ["namespace", "node_id"]
        }
    }
]
