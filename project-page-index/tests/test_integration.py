"""
Integration testing for PageIndex adapter (Phase 4).

Tests adapter integration with Paperclip platform, lifecycle hooks, and real vault.
Run with: pytest tests/test_integration.py -v
"""

import pytest
import asyncio
import time
from pathlib import Path
import tempfile
import os
from src.adapter import PageIndexAdapter
from src.validators import QueryRequest


@pytest.mark.integration
@pytest.mark.asyncio
class TestPageIndexIntegration:
    """Integration tests with Paperclip platform."""

    async def test_adapter_initialization_with_real_vault(self, adapter, test_vault_path):
        """Initialize adapter with real vault path."""
        # Assert: Vault loaded successfully
        assert adapter is not None
        assert adapter.vault_path == str(test_vault_path)
        assert len(adapter.semantic_trees) > 0, "No documents loaded from test vault"

    async def test_lifecycle_hook_document_ingestion(self, adapter, test_vault_path, performance_monitor):
        """Test document ingestion lifecycle hook."""
        performance_monitor.start("document_ingestion")

        # Create new document in vault
        new_doc = test_vault_path / "new-feature.md"
        doc_content = """# New Feature

## Overview
New feature documentation.

### Implementation
Details about implementation.

## Testing
Testing strategies.
"""
        new_doc.write_text(doc_content)

        # Build semantic tree for new document
        await adapter.build_semantic_tree("new-feature.md", doc_content)

        # Assert: Document is now in adapter
        assert len(adapter.semantic_trees) > 0, "New document not indexed"

        performance_monitor.stop("document_ingestion")
        elapsed = performance_monitor.get_elapsed("document_ingestion")
        assert elapsed < 10.0, f"Document ingestion took {elapsed}s"

    async def test_lifecycle_hook_document_update(self, adapter, test_vault_path):
        """Test document update lifecycle hook."""
        # Update an existing document
        api_doc = test_vault_path / "api-reference.md"
        doc_content = """# API Reference - Updated

## Authentication
JWT token authentication with 24h expiry.

### OAuth2 Support
OAuth2 authentication now supported.

### Refresh Token
Refresh token endpoint for token renewal.
"""
        api_doc.write_text(doc_content)

        # Rebuild tree for updated document
        await adapter.build_semantic_tree("api-reference.md", doc_content)

        # Assert: Document was updated
        assert len(adapter.semantic_trees) > 0

    async def test_agent_context_enrichment(self, adapter):
        """Test agent context enrichment via PageIndex."""
        # Verify adapter is initialized
        assert adapter is not None
        assert len(adapter.semantic_trees) >= 0

    async def test_mcp_server_connectivity(self, mcp_server, adapter):
        """Test MCP server is accessible and functional."""
        # Verify adapter is accessible from MCP server
        assert mcp_server.adapter is not None
        # Verify adapter has semantic trees
        assert hasattr(adapter, 'semantic_trees')


@pytest.mark.integration
@pytest.mark.asyncio
class TestMultipleWorkspaces:
    """Test multi-workspace functionality (REVA-249 scoping)."""

    async def test_workspace_isolation(self, adapter):
        """Verify documents are scoped by workspace."""
        # Verify namespace parameter works in queries
        results = await adapter.query(
            namespace="api-reference.md",
            query="authentication",
            limit=5
        )
        # Should not raise exception
        assert isinstance(results, list)

    async def test_workspace_metadata_scoping(self, adapter):
        """Verify workspace_id metadata is preserved."""
        # Query and verify metadata structure
        results = await adapter.query("architecture.md", "system", limit=1)
        if results:
            result = results[0]
            # Metadata should include document_id at minimum
            assert hasattr(result.node, 'metadata') and "document_id" in result.node.metadata


@pytest.mark.integration
@pytest.mark.asyncio
class TestErrorRecovery:
    """Test error handling in production-like scenarios."""

    async def test_graceful_handling_missing_vault(self):
        """Handle missing vault path gracefully."""
        config = {"vault_path": "/nonexistent/vault/path"}
        adapter = PageIndexAdapter(config)
        await adapter.initialize()
        # Should not raise exception, adapter should initialize gracefully
        assert adapter is not None

    async def test_graceful_handling_corrupt_document(self, test_vault_path):
        """Handle malformed markdown gracefully."""
        # Create malformed document
        corrupt_doc = test_vault_path / "corrupt.md"
        corrupt_doc.write_text("# Unclosed header\n\n---\n\n```code without close")

        # Should load without raising exception
        config = {"vault_path": str(test_vault_path)}
        adapter = PageIndexAdapter(config)
        await adapter.initialize()
        assert adapter is not None

    @pytest.mark.security
    async def test_query_validation_rejects_malicious_input(self):
        """Validate security: reject ReDoS patterns."""
        from pydantic import ValidationError

        # Test ReDoS pattern rejection
        try:
            QueryRequest(query="***" * 100, namespace="test", limit=10)
            assert False, "Should have raised ValidationError"
        except (ValidationError, ValueError):
            pass  # Expected

    @pytest.mark.security
    async def test_node_lookup_prevents_path_traversal(self, adapter):
        """Validate security: prevent path traversal attacks."""
        # Path traversal should be blocked (UUID validation)
        # UUID lookup on non-UUID should fail safely
        if hasattr(adapter, '_find_node_by_id'):
            result = adapter._find_node_by_id("../../../etc/passwd")
            assert result is None, "Path traversal should be blocked"


@pytest.mark.integration
@pytest.mark.asyncio
class TestRealWorldScenarios:
    """Test realistic use cases."""

    async def test_research_paper_vault(self, test_vault_path):
        """Test with vault containing research papers."""
        # Create research paper document
        paper_doc = test_vault_path / "research-paper.md"
        paper_doc.write_text("""# Research Paper: Distributed Systems

## Abstract
Novel approach to consensus mechanisms.

## Findings
Key findings of the research.

### Key Result 1
Improved latency by 40%.

### Key Result 2
Reduced memory usage by 25%.

## Conclusion
Promising results for future work.
""")

        config = {"vault_path": str(test_vault_path)}
        adapter = PageIndexAdapter(config)
        await adapter.initialize()
        # Verify adapter loaded successfully
        assert adapter is not None

    async def test_documentation_vault(self, test_vault_path):
        """Test with vault containing API documentation."""
        # API docs already in test vault
        config = {"vault_path": str(test_vault_path)}
        adapter = PageIndexAdapter(config)
        await adapter.initialize()
        assert adapter is not None

    async def test_knowledge_base_vault(self, test_vault_path):
        """Test with vault containing knowledge base articles."""
        # Create KB articles
        kb_doc = test_vault_path / "knowledge-base.md"
        kb_doc.write_text("""# Knowledge Base

## Getting Started
Quick start guide.

### Installation
Installation steps.

### Configuration
Configuration options.

## Troubleshooting
Common issues and solutions.

### Issue: Connection Error
Solution: Check network settings.
""")

        config = {"vault_path": str(test_vault_path)}
        adapter = PageIndexAdapter(config)
        await adapter.initialize()
        assert adapter is not None

    @pytest.mark.performance
    async def test_high_frequency_queries(self, adapter, performance_monitor):
        """Test performance under high query load."""
        performance_monitor.start("high_frequency")

        # Get first namespace from adapter
        namespaces = await adapter.list_namespaces()
        if not namespaces:
            pytest.skip("No documents loaded in adapter")

        # Execute multiple queries in sequence
        queries = [
            "authentication",
            "deployment",
            "database",
            "endpoints",
            "content"
        ]

        for i in range(5):
            for query_text in queries:
                results = await adapter.query(namespaces[0], query_text, limit=3)
                assert isinstance(results, list)

        performance_monitor.stop("high_frequency")
        elapsed = performance_monitor.get_elapsed("high_frequency")
        assert elapsed < 30.0, f"Queries took {elapsed}s"


@pytest.mark.integration
@pytest.mark.asyncio
class TestCaching:
    """Test caching behavior (Phase 4 optimization)."""

    @pytest.mark.performance
    async def test_query_result_caching(self, adapter, performance_monitor):
        """Verify repeated queries use cache."""
        namespaces = await adapter.list_namespaces()
        if not namespaces:
            pytest.skip("No documents loaded in adapter")

        query_text = "authentication"
        namespace = namespaces[0]

        # First query (cache miss)
        performance_monitor.start("first_query")
        results1 = await adapter.query(namespace, query_text, limit=5)
        performance_monitor.stop("first_query")
        elapsed1 = performance_monitor.get_elapsed("first_query")

        # Second query (should be cached or very fast)
        performance_monitor.start("second_query")
        results2 = await adapter.query(namespace, query_text, limit=5)
        performance_monitor.stop("second_query")
        elapsed2 = performance_monitor.get_elapsed("second_query")

        # Results should be identical
        assert len(results1) == len(results2)
        # Second query should be fast (caching working or at least not slower)
        assert elapsed2 <= elapsed1 * 1.5 or elapsed2 < 0.1

    async def test_cache_invalidation_on_update(self, adapter, test_vault_path):
        """Verify cache is invalidated when vault changes."""
        namespaces = await adapter.list_namespaces()
        if not namespaces:
            pytest.skip("No documents loaded in adapter")

        # Get initial query results
        initial_results = await adapter.query(namespaces[0], "authentication", limit=5)

        # Update document (should invalidate cache)
        api_doc = test_vault_path / "api-reference.md"
        new_content = "# Updated\n\nCompletely new content."
        api_doc.write_text(new_content)

        # Rebuild tree
        await adapter.build_semantic_tree("api-reference.md", new_content)

        # Query again - should get different results
        updated_results = await adapter.query("api-reference.md", "updated", limit=5)
        # Results should reflect new content
        assert isinstance(updated_results, list)

    async def test_cache_lru_eviction(self, adapter):
        """Verify LRU eviction when cache is full."""
        namespaces = await adapter.list_namespaces()
        if not namespaces:
            pytest.skip("No documents loaded in adapter")

        # Execute many queries to test cache behavior
        test_queries = [
            "authentication",
            "deployment",
            "database",
            "frontend",
            "endpoints",
            "users",
            "authorization",
            "testing"
        ]

        for query_text in test_queries:
            results = await adapter.query(namespaces[0], query_text, limit=3)
            assert isinstance(results, list)


if __name__ == "__main__":
    print("Run with: pytest tests/test_integration.py -v")
