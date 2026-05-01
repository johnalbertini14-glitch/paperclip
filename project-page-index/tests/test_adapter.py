"""Tests for PageIndex adapter."""
# pylint: disable=redefined-outer-name,protected-access

import unittest
import pytest
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


class TestAdapterQueryMatching(unittest.TestCase):
    """Test query matching logic."""

    def setUp(self):
        self.config = {
            "vault_path": "~/test_vault/",
            "hierarchy_depth_limit": 5
        }
        self.adapter = PageIndexAdapter(self.config)

    def test_matches_query_single_term(self):
        """Test matching with single query term."""
        self.assertTrue(self.adapter._matches_query("Database Design", "database"))
        self.assertTrue(self.adapter._matches_query("Database Design", "design"))
        self.assertFalse(self.adapter._matches_query("Database Design", "query"))

    def test_matches_query_multiple_terms(self):
        """Test matching with multiple query terms."""
        text = "Advanced Database Architecture"
        self.assertTrue(self.adapter._matches_query(text, "database architecture"))
        self.assertTrue(self.adapter._matches_query(text, "advanced design"))  # design not in text
        self.assertFalse(self.adapter._matches_query(text, "nosql"))

    def test_matches_query_case_insensitive(self):
        """Test that matching is case-insensitive."""
        self.assertTrue(self.adapter._matches_query("DATABASE", "database"))
        self.assertTrue(self.adapter._matches_query("Design", "design"))

    def test_matches_query_empty_terms(self):
        """Test matching with empty query terms."""
        # Empty query has no terms, so any() returns False
        self.assertFalse(self.adapter._matches_query("Any Text", ""))

    def test_matches_query_special_characters(self):
        """Test matching with special characters."""
        self.assertTrue(self.adapter._matches_query("C++ Programming", "c++"))
        self.assertTrue(self.adapter._matches_query("Node.js Guide", "node.js"))


class TestAdapterRelevanceScoring(unittest.TestCase):
    """Test relevance scoring logic."""

    def setUp(self):
        self.config = {
            "vault_path": "~/test_vault/",
            "hierarchy_depth_limit": 5
        }
        self.adapter = PageIndexAdapter(self.config)

    def test_relevance_perfect_match(self):
        """Test relevance score for perfect match."""
        score = self.adapter._calculate_relevance("Database", "database")
        self.assertEqual(score, 1.0)

    def test_relevance_partial_match(self):
        """Test relevance score for partial match."""
        score = self.adapter._calculate_relevance("Database Design", "database design")
        self.assertEqual(score, 1.0)

    def test_relevance_one_of_two_terms(self):
        """Test relevance score when one of two terms matches."""
        # One of two terms matches (database), plus starts with first term bonus
        score = self.adapter._calculate_relevance("Database Queries", "database missing")
        self.assertEqual(score, 0.7)  # 0.5 + 0.2 bonus

    def test_relevance_starting_with_query(self):
        """Test bonus score when text starts with query term."""
        # With more query terms, the bonus becomes visible
        score1 = self.adapter._calculate_relevance("Database Management Systems", "database management python")
        score2 = self.adapter._calculate_relevance("Managing Database Systems", "database management python")
        # First has 2 matches + bonus, second has 2 matches but no bonus
        self.assertGreater(score1, score2)

    def test_relevance_no_match(self):
        """Test relevance score with no match."""
        score = self.adapter._calculate_relevance("Python Programming", "javascript")
        self.assertEqual(score, 0.0)

    def test_relevance_score_capped_at_one(self):
        """Test that relevance score is capped at 1.0."""
        score = self.adapter._calculate_relevance("query query query", "query query")
        self.assertLessEqual(score, 1.0)

    def test_relevance_empty_query(self):
        """Test relevance with empty query."""
        score = self.adapter._calculate_relevance("Any Text", "")
        self.assertEqual(score, 0.0)


class TestAdapterNodeConversion(unittest.TestCase):
    """Test semantic node tree conversion."""

    def setUp(self):
        self.config = {
            "vault_path": "~/test_vault/",
            "hierarchy_depth_limit": 5
        }
        self.adapter = PageIndexAdapter(self.config)

    def test_convert_dict_to_node_simple(self):
        """Test converting simple dict to node."""
        node_dict = {
            "title": "Section",
            "children": []
        }
        node = self.adapter._convert_dict_to_node(node_dict, "doc1", [], 0)

        self.assertEqual(node.title, "Section")
        self.assertEqual(node.level, 0)
        self.assertEqual(len(node.children), 0)
        self.assertEqual(node.metadata["document_id"], "doc1")

    def test_convert_dict_to_node_with_children(self):
        """Test converting dict with children to node."""
        node_dict = {
            "title": "Parent",
            "children": [
                {"title": "Child1", "children": []},
                {"title": "Child2", "children": []}
            ]
        }
        node = self.adapter._convert_dict_to_node(node_dict, "doc1", [], 0)

        self.assertEqual(len(node.children), 2)
        self.assertEqual(node.children[0].title, "Child1")
        self.assertEqual(node.children[0].level, 1)

    def test_convert_dict_to_node_nested(self):
        """Test converting deeply nested dict."""
        node_dict = {
            "title": "Level1",
            "children": [
                {
                    "title": "Level2",
                    "children": [
                        {"title": "Level3", "children": []}
                    ]
                }
            ]
        }
        node = self.adapter._convert_dict_to_node(node_dict, "doc1", [], 0)

        self.assertEqual(node.children[0].level, 1)
        self.assertEqual(node.children[0].children[0].level, 2)

    def test_convert_dict_to_node_root_title(self):
        """Test that root title doesn't add to path."""
        node_dict = {"title": "root", "children": []}
        node = self.adapter._convert_dict_to_node(node_dict, "doc1", [], 0)

        self.assertEqual(len(node.path), 0)

    def test_convert_dict_to_node_path_building(self):
        """Test path building during conversion."""
        node_dict = {
            "title": "Parent",
            "children": [
                {"title": "Child", "children": []}
            ]
        }
        node = self.adapter._convert_dict_to_node(node_dict, "doc1", [], 0)
        child = node.children[0]

        self.assertEqual(child.path, ["Parent", "Child"])

    def test_convert_dict_to_node_metadata_preservation(self):
        """Test that metadata is preserved."""
        node_dict = {
            "title": "Section",
            "content_range": (0, 100),
            "position": 5,
            "children": []
        }
        node = self.adapter._convert_dict_to_node(node_dict, "doc1", [], 0)

        self.assertEqual(node.metadata["content_range"], (0, 100))
        self.assertEqual(node.metadata["position"], 5)


class TestAdapterHierarchyTraversal:
    """Test semantic tree hierarchy traversal."""

    @pytest.fixture(autouse=True)
    def setup(self):
        """Set up test fixtures."""
        self.config = {
            "vault_path": "~/test_vault/",
            "hierarchy_depth_limit": 3
        }
        self.adapter = PageIndexAdapter(self.config)

    @pytest.mark.asyncio
    async def test_traverse_flat_tree(self):
        """Test traversing flat tree."""
        child1 = SemanticNode("c1", "Child1", "", ["root", "c1"], 1)
        child2 = SemanticNode("c2", "Child2", "", ["root", "c2"], 1)
        root = SemanticNode("root", "Root", "", [], 0, children=[child1, child2])

        nodes = await self.adapter.traverse_hierarchy(root)

        assert len(nodes) == 3
        assert nodes[0].title == "Root"

    @pytest.mark.asyncio
    async def test_traverse_deep_tree(self):
        """Test traversing deeply nested tree."""
        level3 = SemanticNode("l3", "Level3", "", ["root", "l2", "l3"], 3)
        level2 = SemanticNode("l2", "Level2", "", ["root", "l2"], 2, children=[level3])
        level1 = SemanticNode("l1", "Level1", "", ["root", "l1"], 1, children=[level2])
        root = SemanticNode("root", "Root", "", [], 0, children=[level1])

        nodes = await self.adapter.traverse_hierarchy(root)

        assert len(nodes) >= 3

    @pytest.mark.asyncio
    async def test_traverse_respects_depth_limit(self):
        """Test that traversal respects depth limit."""
        # Create tree deeper than limit (3)
        level4 = SemanticNode("l4", "Level4", "", ["root", "l3", "l4"], 4)
        level3 = SemanticNode("l3", "Level3", "", ["root", "l2", "l3"], 3, children=[level4])
        level2 = SemanticNode("l2", "Level2", "", ["root", "l2"], 2, children=[level3])
        level1 = SemanticNode("l1", "Level1", "", ["root", "l1"], 1, children=[level2])
        root = SemanticNode("root", "Root", "", [], 0, children=[level1])

        nodes = await self.adapter.traverse_hierarchy(root)

        # Level4 should not be included due to depth limit
        max_level = max(n.level for n in nodes)
        assert max_level <= 3


class TestAdapterGetHierarchyContext(unittest.TestCase):
    """Test hierarchy context retrieval."""

    def setUp(self):
        self.config = {
            "vault_path": "~/test_vault/",
            "hierarchy_depth_limit": 5
        }
        self.adapter = PageIndexAdapter(self.config)

    def test_get_hierarchy_context_root(self):
        """Test context for root node."""
        node = SemanticNode("root", "Root", "", [], 0)
        context = self.adapter._get_hierarchy_context(node)

        self.assertEqual(context, [])

    def test_get_hierarchy_context_nested(self):
        """Test context for nested node."""
        path = ["root", "section", "subsection"]
        node = SemanticNode("node", "Title", "", path, 3)
        context = self.adapter._get_hierarchy_context(node)

        self.assertEqual(context, path)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
