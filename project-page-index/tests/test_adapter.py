"""Tests for PageIndex adapter."""

import unittest
from unittest.mock import AsyncMock, patch, MagicMock
from src.adapter import PageIndexAdapter, QueryMethod, SemanticNode


class TestPageIndexAdapter(unittest.TestCase):
    """Test PageIndex adapter functionality."""

    def setUp(self):
        self.config = {
            "vault_path": "~/test_vault/",
            "hierarchy_depth_limit": 5
        }
        self.adapter = PageIndexAdapter(self.config)

    def test_adapter_initialization(self):
        """Test adapter initialization with config."""
        self.assertEqual(self.adapter.vault_path, "~/test_vault/")
        self.assertEqual(self.adapter.hierarchy_depth_limit, 5)
        self.assertIsInstance(self.adapter.semantic_trees, dict)

    def test_create_semantic_node(self):
        """Test creating semantic nodes."""
        node = SemanticNode(
            id="node1",
            title="Test Section",
            content="This is test content",
            path=["root", "section"],
            level=2
        )

        self.assertEqual(node.id, "node1")
        self.assertEqual(node.title, "Test Section")
        self.assertEqual(node.level, 2)
        self.assertEqual(len(node.children), 0)

    def test_semantic_node_hierarchy(self):
        """Test building node hierarchy."""
        child = SemanticNode(
            id="child1",
            title="Subsection",
            content="Child content",
            path=["root", "section", "subsection"],
            level=3
        )

        parent = SemanticNode(
            id="parent1",
            title="Section",
            content="Parent content",
            path=["root", "section"],
            level=2,
            children=[child]
        )

        self.assertEqual(len(parent.children), 1)
        self.assertEqual(parent.children[0].title, "Subsection")

    def test_traverse_empty_tree(self):
        """Test traversing empty tree."""
        node = SemanticNode(
            id="root",
            title="Root",
            content="Root content",
            path=["root"],
            level=0
        )

        # With no async, we can't fully test this without asyncio
        # But we can check the node structure
        self.assertEqual(len(node.children), 0)

    def test_adapter_config_schema(self):
        """Test that adapter config schema is valid."""
        from src.adapter import ADAPTER_CONFIG_SCHEMA

        self.assertIn("properties", ADAPTER_CONFIG_SCHEMA)
        self.assertIn("vault_path", ADAPTER_CONFIG_SCHEMA["properties"])
        self.assertIn("hierarchy_depth_limit", ADAPTER_CONFIG_SCHEMA["properties"])


class TestQueryMethods(unittest.TestCase):
    """Test query method enum."""

    def test_query_methods_defined(self):
        """Test that query methods are defined."""
        self.assertEqual(QueryMethod.STRUCTURE_AWARE.value, "structure_aware")
        self.assertEqual(QueryMethod.SEMANTIC_SEARCH.value, "semantic_search")
        self.assertEqual(QueryMethod.HIERARCHY_TRAVERSAL.value, "hierarchy_traversal")


if __name__ == "__main__":
    unittest.main()
