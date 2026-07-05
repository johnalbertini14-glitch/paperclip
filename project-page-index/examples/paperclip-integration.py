"""
Example: Integrating PageIndex into Paperclip Platform

Shows how to:
1. Initialize PageIndex adapter in Paperclip
2. Register lifecycle hooks
3. Expose MCP tools to agents
4. Use PageIndex for agent context enrichment

This is a template for Phase 4 integration. Actual integration happens in Paperclip core.
"""

import asyncio
from typing import Optional, List, Dict, Any

# Hypothetical Paperclip imports (would be actual imports in production)
# from paperclip.platform import PlatformAdapter, LifecycleHook
# from paperclip.mcp import MCPServer, MCPTool
# from paperclip.agents import Agent

# Real imports (when installed in /paperclip/.claude/)
from src.adapter import PageIndexAdapter
from src.mcp_server import PageIndexMCPServer
from src.validators import PageIndexConfig


class PaperclipPageIndexIntegration:
    """Integration layer between Paperclip and PageIndex adapter."""

    def __init__(self, agent_config: Dict[str, Any]):
        """Initialize integration with agent configuration."""
        self.agent_config = agent_config

        # Extract PageIndex config from agent config
        self.pageindex_config = PageIndexConfig(
            vault_path=agent_config.get(
                "vault_path",
                "~/Albertini Brain/"
            ),
            hierarchy_depth_limit=agent_config.get(
                "hierarchy_depth_limit",
                10
            ),
            mcp_server_enabled=agent_config.get(
                "mcp_server_enabled",
                True
            ),
            mcp_server_port=agent_config.get(
                "mcp_server_port",
                8001
            )
        )

        # Initialize adapter and MCP server
        self.adapter: Optional[PageIndexAdapter] = None
        self.mcp_server: Optional[PageIndexMCPServer] = None

    async def initialize(self):
        """Initialize adapter and MCP server."""
        self.adapter = PageIndexAdapter(self.pageindex_config.model_dump())
        self.mcp_server = PageIndexMCPServer(self.adapter)
        await self.mcp_server.initialize()

    async def shutdown(self):
        """Cleanup on shutdown."""
        # Cleanup code here
        pass


# ============================================================================
# LIFECYCLE HOOKS - Integrate with Paperclip document pipeline
# ============================================================================

async def on_document_ingested(
    doc_id: str,
    content: str,
    metadata: Dict[str, Any],
    pageindex: PaperclipPageIndexIntegration
) -> bool:
    """
    Lifecycle hook: Called when a new document is ingested into vault.

    Paperclip would call this when:
    - New document added to vault (sync from filesystem)
    - Document updated (sync from source)
    - Document imported (from external source)

    Args:
        doc_id: Document identifier (e.g., "notes/api-design.md")
        content: Document content (markdown)
        metadata: Document metadata (source, timestamp, tags, etc.)
        pageindex: PageIndex integration instance

    Returns:
        bool: True if indexing succeeded, False if failed
    """
    try:
        # Build semantic tree for document
        await pageindex.adapter.build_semantic_tree(
            document_id=doc_id,
            content=content
        )
        print(f"✅ Indexed document: {doc_id}")
        return True

    except Exception as e:
        print(f"❌ Failed to index {doc_id}: {e}")
        return False


async def on_document_deleted(
    doc_id: str,
    pageindex: PaperclipPageIndexIntegration
) -> bool:
    """
    Lifecycle hook: Called when document is deleted from vault.

    Args:
        doc_id: Document identifier
        pageindex: PageIndex integration instance

    Returns:
        bool: True if removal succeeded
    """
    try:
        # Remove from semantic trees cache
        if doc_id in pageindex.adapter.semantic_trees:
            del pageindex.adapter.semantic_trees[doc_id]
            print(f"✅ Removed document: {doc_id}")
            return True
        return False

    except Exception as e:
        print(f"❌ Failed to remove {doc_id}: {e}")
        return False


# ============================================================================
# AGENT CONTEXT ENRICHMENT - Provide PageIndex results to agents
# ============================================================================

async def enrich_agent_context(
    agent_id: str,
    user_query: str,
    pageindex: PaperclipPageIndexIntegration,
    limit: int = 5
) -> List[Dict[str, Any]]:
    """
    Enrich agent context with relevant documents from vault.

    Paperclip agents call this when they need background information:
    - Agent: "What's the API design for user endpoints?"
    - PageIndex returns: Top-5 sections mentioning "user" in design docs

    Args:
        agent_id: Agent identifier (for logging/metrics)
        user_query: The agent's query
        pageindex: PageIndex integration instance
        limit: Maximum results to return

    Returns:
        List of relevant document sections with hierarchy context
    """
    try:
        # Query vault for relevant documents
        # Use workspace_id scoping if multi-tenant
        workspace_id = f"agent_{agent_id}"

        results = await pageindex.adapter.query(
            namespace=workspace_id,
            query=user_query,
            limit=limit
        )

        # Convert results to context format
        context = []
        for result in results:
            context.append({
                "title": result.node.title,
                "path": " → ".join(result.hierarchy_context),
                "relevance_score": result.relevance_score,
                "matched_content": result.matched_content,
                "document_id": result.node.metadata.get("document_id")
            })

        return context

    except Exception as e:
        print(f"⚠️ Context enrichment failed for {agent_id}: {e}")
        return []


# ============================================================================
# MCP TOOLS - Expose PageIndex to agents via MCP
# ============================================================================

class PageIndexMCPTools:
    """MCP tool adapters for Paperclip integration."""

    def __init__(self, mcp_server: PageIndexMCPServer):
        self.mcp_server = mcp_server

    def get_semantic_tree(self, namespace: str) -> Dict[str, Any]:
        """
        MCP Tool: Get semantic tree structure

        Exposes: get_semantic_tree
        Used by: Agents exploring document structure
        """
        # Asyncio bridge (MCP tools are called synchronously)
        loop = asyncio.new_event_loop()
        try:
            tree = loop.run_until_complete(
                self.mcp_server.get_semantic_tree(namespace)
            )
            return tree or {"error": "Namespace not found"}
        finally:
            loop.close()

    def query_tree(
        self,
        namespace: str,
        query: str,
        method: str = "structure_aware",
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """
        MCP Tool: Query semantic tree

        Exposes: query_tree
        Used by: Agents searching for relevant information
        """
        loop = asyncio.new_event_loop()
        try:
            results = loop.run_until_complete(
                self.mcp_server.query_tree(
                    namespace=namespace,
                    query=query,
                    method=method,
                    limit=limit
                )
            )
            return results
        finally:
            loop.close()

    def list_documents(self) -> List[str]:
        """
        MCP Tool: List available documents

        Exposes: list_documents
        Used by: Agents discovering available vaults
        """
        loop = asyncio.new_event_loop()
        try:
            docs = loop.run_until_complete(
                self.mcp_server.list_documents()
            )
            return docs
        finally:
            loop.close()

    def get_document_section(
        self,
        namespace: str,
        node_id: str,
        include_hierarchy: bool = True
    ) -> Dict[str, Any]:
        """
        MCP Tool: Get document section details

        Exposes: get_document_section
        Used by: Agents retrieving specific sections with context
        """
        loop = asyncio.new_event_loop()
        try:
            section = loop.run_until_complete(
                self.mcp_server.get_document_section(
                    namespace=namespace,
                    node_id=node_id,
                    include_hierarchy=include_hierarchy
                )
            )
            return section or {"error": "Section not found"}
        finally:
            loop.close()


# ============================================================================
# USAGE EXAMPLE - How Paperclip would use PageIndex
# ============================================================================

async def example_paperclip_usage():
    """
    Example of how Paperclip platform integrates PageIndex.

    This shows:
    1. Initialization
    2. Lifecycle hook registration
    3. Agent context enrichment
    4. MCP tool exposure
    """

    # 1. INITIALIZATION
    print("1. Initializing PageIndex...")
    config = {
        "vault_path": "~/Albertini Brain/",
        "hierarchy_depth_limit": 10,
        "mcp_server_enabled": True,
        "mcp_server_port": 8001
    }
    pageindex = PaperclipPageIndexIntegration(config)
    await pageindex.initialize()
    print("✅ PageIndex initialized")

    # 2. DOCUMENT INGESTION
    print("\n2. Simulating document ingestion...")
    await on_document_ingested(
        doc_id="api-design.md",
        content="# API Design\n## Users\nUser endpoints...",
        metadata={"source": "vault", "timestamp": "2026-04-24"},
        pageindex=pageindex
    )

    # 3. AGENT CONTEXT ENRICHMENT
    print("\n3. Enriching agent context...")
    context = await enrich_agent_context(
        agent_id="code-worker-a",
        user_query="user authentication endpoints",
        pageindex=pageindex,
        limit=3
    )
    print(f"Found {len(context)} relevant sections")
    for section in context:
        print(f"  - {section['title']} ({section['relevance_score']:.2f})")

    # 4. MCP TOOLS
    print("\n4. Registering MCP tools...")
    mcp_tools = PageIndexMCPTools(pageindex.mcp_server)
    print("Available MCP tools:")
    print("  - get_semantic_tree(namespace)")
    print("  - query_tree(namespace, query, method, limit)")
    print("  - list_documents()")
    print("  - get_document_section(namespace, node_id, include_hierarchy)")

    # 5. CLEANUP
    print("\n5. Shutting down...")
    await pageindex.shutdown()
    print("✅ PageIndex shut down cleanly")


# ============================================================================
# DEPLOYMENT TEMPLATE
# ============================================================================

# This is how Paperclip would deploy PageIndex in its initialization:
"""
# In paperclip/platform/adapters.py or similar:

async def load_pageindex_adapter(agent_config: Dict) -> Optional[PaperclipPageIndexIntegration]:
    '''Load and initialize PageIndex adapter if enabled.'''
    if not agent_config.get("adapters", {}).get("pageindex", {}).get("enabled"):
        return None

    pageindex_config = agent_config["adapters"]["pageindex"]
    pageindex = PaperclipPageIndexIntegration(pageindex_config)

    try:
        await pageindex.initialize()

        # Register lifecycle hooks
        agent.register_hook("on_document_ingested",
                          lambda doc_id, content, meta: on_document_ingested(
                              doc_id, content, meta, pageindex))
        agent.register_hook("on_document_deleted",
                          lambda doc_id: on_document_deleted(doc_id, pageindex))

        # Register MCP tools
        mcp_tools = PageIndexMCPTools(pageindex.mcp_server)
        agent.register_mcp_tools([
            MCP_TOOL("get_semantic_tree", mcp_tools.get_semantic_tree),
            MCP_TOOL("query_tree", mcp_tools.query_tree),
            MCP_TOOL("list_documents", mcp_tools.list_documents),
            MCP_TOOL("get_document_section", mcp_tools.get_document_section),
        ])

        return pageindex

    except Exception as e:
        logger.error(f"Failed to initialize PageIndex: {e}")
        return None
"""


if __name__ == "__main__":
    # Run example
    asyncio.run(example_paperclip_usage())
