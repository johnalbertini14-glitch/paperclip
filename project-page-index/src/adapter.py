"""
PageIndex Semantic Tree Adapter for Paperclip Platform.

Provides vectorless reasoning-based RAG through hierarchical semantic tree indices
as alternative to vector search for structured documents.
"""

from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field
from enum import Enum
import logging
import os
from pathlib import Path
import uuid
from .semantic_tree import SemanticTreeBuilder

logger = logging.getLogger(__name__)


class QueryMethod(Enum):
    """Query methods for semantic tree search."""
    STRUCTURE_AWARE = "structure_aware"
    SEMANTIC_SEARCH = "semantic_search"
    HIERARCHY_TRAVERSAL = "hierarchy_traversal"


@dataclass
class SemanticNode:
    """Node in semantic tree hierarchy."""
    id: str
    title: str
    content: str
    path: List[str]
    level: int
    children: List["SemanticNode"] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class SearchResult:
    """Result from semantic tree query."""
    node: SemanticNode
    relevance_score: float
    hierarchy_context: List[str]
    matched_content: str


class PageIndexAdapter:
    """
    Semantic tree document processing adapter.

    Transforms documents into hierarchical TOC structures for semantic traversal
    without requiring vector embeddings.
    """

    def __init__(self, config: Dict[str, Any]):
        """Initialize PageIndex adapter with configuration."""
        self.config = config
        self.vault_path = config.get("vault_path", "~/Albertini Brain/")
        self.hierarchy_depth_limit = config.get("hierarchy_depth_limit", 10)
        self.semantic_trees: Dict[str, SemanticNode] = {}
        self.logger = logger

    async def initialize(self) -> None:
        """Initialize adapter and load document vault."""
        self.logger.info("Initializing PageIndex adapter with vault: %s", self.vault_path)
        await self._load_vault()

    async def _load_vault(self) -> None:
        """Load documents from vault and build semantic trees."""
        vault_path = Path(os.path.expanduser(self.vault_path))

        if not vault_path.exists():
            self.logger.warning("Vault path does not exist: %s", vault_path)
            return

        self.logger.info("Loading vault from %s", vault_path)

        markdown_files = list(vault_path.glob("**/*.md"))
        self.logger.info("Found %d markdown files in vault", len(markdown_files))

        for md_file in markdown_files:
            try:
                with open(md_file, "r", encoding="utf-8") as f:
                    content = f.read()

                doc_id = str(md_file.relative_to(vault_path))
                await self.build_semantic_tree(doc_id, content)
                self.logger.debug("Loaded document: %s", doc_id)
            except (OSError, UnicodeDecodeError) as e:
                self.logger.error("Error loading document %s: %s", md_file, e)

    async def build_semantic_tree(
        self,
        document_id: str,
        content: str
    ) -> SemanticNode:
        """
        Build semantic tree from document content.

        Transforms document into hierarchical structure preserving semantics.
        """
        builder = SemanticTreeBuilder()
        tree_data = builder.build_tree(document_id, content)

        root_node = self._convert_dict_to_node(
            tree_data["tree"],
            document_id,
            path=[],
            level=0
        )

        self.semantic_trees[document_id] = root_node
        self.logger.debug(
            "Built semantic tree for %s with %d headings",
            document_id, tree_data['headings_count']
        )

        return root_node

    def _convert_dict_to_node(
        self,
        node_dict: Dict[str, Any],
        document_id: str,
        path: List[str],
        level: int
    ) -> SemanticNode:
        """Convert dictionary tree to SemanticNode hierarchy."""
        node_id = str(uuid.uuid4())
        title = node_dict.get("title", "root")
        current_path = path + [title] if title != "root" else path

        node = SemanticNode(
            id=node_id,
            title=title,
            content="",
            path=current_path,
            level=level,
            children=[],
            metadata={
                "document_id": document_id,
                "content_range": node_dict.get("content_range"),
                "position": node_dict.get("position")
            }
        )

        for child_dict in node_dict.get("children", []):
            child_node = self._convert_dict_to_node(
                child_dict,
                document_id,
                current_path,
                level + 1
            )
            node.children.append(child_node)

        return node

    async def query(
        self,
        namespace: str,
        query: str,
        method: QueryMethod = QueryMethod.STRUCTURE_AWARE,  # pylint: disable=unused-argument
        limit: int = 10
    ) -> List[SearchResult]:
        """
        Query semantic tree index.

        Returns relevant document sections based on query and hierarchy.

        Args:
            namespace: Document namespace to query
            query: Search query string
            method: Query method (reserved for future implementations,
                currently only STRUCTURE_AWARE)
            limit: Maximum results to return

        Returns:
            List of SearchResult objects matching the query
        """
        tree = self.semantic_trees.get(namespace)
        if not tree:
            self.logger.warning("No semantic tree found for namespace: %s", namespace)
            return []

        # Structure-aware query: traverse hierarchy and match on titles
        query_lower = query.lower()
        results = []

        nodes = await self.traverse_hierarchy(tree)
        for node in nodes[1:]:
            if self._matches_query(node.title, query_lower):
                score = self._calculate_relevance(node.title, query_lower)
                context = self._get_hierarchy_context(node)

                result = SearchResult(
                    node=node,
                    relevance_score=score,
                    hierarchy_context=context,
                    matched_content=node.title
                )
                results.append(result)

        results.sort(key=lambda r: r.relevance_score, reverse=True)
        return results[:limit]

    def _matches_query(self, text: str, query: str) -> bool:
        """Check if text contains query terms."""
        text_lower = text.lower()
        query_terms = query.split()
        return any(term in text_lower for term in query_terms)

    def _calculate_relevance(self, text: str, query: str) -> float:
        """Calculate relevance score (0.0-1.0) for text vs query."""
        text_lower = text.lower()
        query_terms = query.split()

        if not query_terms:
            return 0.0

        matches = sum(1 for term in query_terms if term in text_lower)
        score = matches / len(query_terms)

        if text_lower.startswith(query.split()[0]):
            score = min(1.0, score + 0.2)

        return min(1.0, score)

    def _get_hierarchy_context(self, node: SemanticNode) -> List[str]:
        """Get parent hierarchy path for a node."""
        return node.path

    async def get_tree(self, namespace: str) -> Optional[SemanticNode]:
        """Get semantic tree for namespace."""
        return self.semantic_trees.get(namespace)

    async def list_namespaces(self) -> List[str]:
        """List all loaded document namespaces."""
        return list(self.semantic_trees.keys())

    async def traverse_hierarchy(
        self,
        node: SemanticNode,
        depth: int = 0
    ) -> List[SemanticNode]:
        """
        Traverse semantic tree hierarchy.

        Returns flattened list of nodes in traversal order.
        """
        results = [node]

        if depth >= self.hierarchy_depth_limit:
            return results

        for child in node.children:
            results.extend(
                await self.traverse_hierarchy(child, depth + 1)
            )

        return results


# Configuration schema
ADAPTER_CONFIG_SCHEMA = {
    "type": "object",
    "properties": {
        "vault_path": {
            "type": "string",
            "default": "~/Albertini Brain/",
            "description": "Path to document vault"
        },
        "hierarchy_depth_limit": {
            "type": "integer",
            "default": 10,
            "description": "Maximum depth for hierarchy traversal"
        },
        "mcp_server_enabled": {
            "type": "boolean",
            "default": True,
            "description": "Enable MCP server integration"
        }
    }
}
