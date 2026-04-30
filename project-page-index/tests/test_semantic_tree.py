"""Tests for semantic tree construction and traversal."""

import unittest
from src.semantic_tree import SemanticTreeBuilder, SemanticTreeTraversal


class TestSemanticTreeBuilder(unittest.TestCase):
    """Test semantic tree builder."""

    def setUp(self):
        self.builder = SemanticTreeBuilder()

    def test_parse_markdown_headings(self):
        """Test parsing markdown headings."""
        content = """# Title
## Section 1
### Subsection 1.1
## Section 2
"""
        headings = self.builder.parse_markdown_headings(content)

        self.assertEqual(len(headings), 4)
        self.assertEqual(headings[0].level, 1)
        self.assertEqual(headings[0].title, "Title")
        self.assertEqual(headings[1].level, 2)
        self.assertEqual(headings[1].title, "Section 1")
        self.assertEqual(headings[2].level, 3)
        self.assertEqual(headings[2].title, "Subsection 1.1")
        self.assertEqual(headings[3].level, 2)
        self.assertEqual(headings[3].title, "Section 2")

    def test_parse_no_headings(self):
        """Test parsing content with no headings."""
        content = "Just some plain text\nwith multiple lines\nno headings"
        headings = self.builder.parse_markdown_headings(content)

        self.assertEqual(len(headings), 0)

    def test_build_hierarchy(self):
        """Test building hierarchy from headings."""
        content = """# Title
## Section 1
### Subsection 1.1
## Section 2
"""
        headings = self.builder.parse_markdown_headings(content)
        hierarchy = self.builder.build_hierarchy(headings)

        self.assertEqual(hierarchy["title"], "root")
        self.assertEqual(len(hierarchy["children"]), 1)  # Title

        title_node = hierarchy["children"][0]
        self.assertEqual(title_node["title"], "Title")
        self.assertEqual(len(title_node["children"]), 2)  # Section 1, Section 2

        section1 = title_node["children"][0]
        self.assertEqual(section1["title"], "Section 1")
        self.assertEqual(len(section1["children"]), 1)  # Subsection 1.1

    def test_extract_section_content(self):
        """Test extracting section content."""
        content = "0123456789"
        section = self.builder.extract_section_content(content, 0, 5)

        self.assertEqual(section, "01234")

    def test_build_tree(self):
        """Test building complete tree."""
        content = """# Main
## Part 1
### Detail 1.1
## Part 2
"""
        tree = self.builder.build_tree("doc1", content)

        self.assertEqual(tree["document_id"], "doc1")
        self.assertEqual(tree["headings_count"], 4)
        self.assertGreater(tree["max_depth"], 0)


class TestSemanticTreeTraversal(unittest.TestCase):
    """Test tree traversal utilities."""

    def setUp(self):
        self.tree = {
            "title": "root",
            "level": 0,
            "children": [
                {
                    "title": "Section 1",
                    "level": 1,
                    "children": [
                        {
                            "title": "Subsection 1.1",
                            "level": 2,
                            "children": []
                        }
                    ]
                },
                {
                    "title": "Section 2",
                    "level": 1,
                    "children": []
                }
            ]
        }

    def test_flatten_tree(self):
        """Test flattening tree."""
        flattened = SemanticTreeTraversal.flatten_tree(self.tree, include_root=False)

        titles = [node["title"] for node in flattened]
        self.assertIn("Section 1", titles)
        self.assertIn("Subsection 1.1", titles)
        self.assertIn("Section 2", titles)
        self.assertEqual(len(flattened), 3)

    def test_find_node_by_title_exact(self):
        """Test finding node by exact title."""
        node = SemanticTreeTraversal.find_node_by_title(
            self.tree,
            "Subsection 1.1",
            exact=True
        )

        self.assertIsNotNone(node)
        self.assertEqual(node["title"], "Subsection 1.1")

    def test_find_node_by_title_partial(self):
        """Test finding node by partial title."""
        node = SemanticTreeTraversal.find_node_by_title(
            self.tree,
            "subsection",
            exact=False
        )

        self.assertIsNotNone(node)
        self.assertEqual(node["title"], "Subsection 1.1")

    def test_find_node_not_found(self):
        """Test finding non-existent node."""
        node = SemanticTreeTraversal.find_node_by_title(
            self.tree,
            "Nonexistent",
            exact=True
        )

        self.assertIsNone(node)

    def test_get_subtree(self):
        """Test getting subtree with depth limit."""
        subtree = SemanticTreeTraversal.get_subtree(self.tree, max_depth=1)

        # Root level and its children, but not deeper
        self.assertEqual(len(subtree["children"]), 2)
        self.assertEqual(len(subtree["children"][0]["children"]), 0)

    def test_get_ancestors(self):
        """Test getting ancestor nodes for a target node."""
        target_node = {"title": "Subsection 1.1"}
        ancestors = SemanticTreeTraversal.get_ancestors(self.tree, target_node)

        # Should include root and Section 1
        ancestor_titles = [node["title"] for node in ancestors]
        self.assertIn("root", ancestor_titles)
        self.assertIn("Section 1", ancestor_titles)
        self.assertGreaterEqual(len(ancestors), 2)

    def test_get_ancestors_root_node(self):
        """Test getting ancestors for root node."""
        target_node = {"title": "root"}
        ancestors = SemanticTreeTraversal.get_ancestors(self.tree, target_node)

        # Root has no ancestors
        self.assertEqual(len(ancestors), 0)

    def test_get_ancestors_not_found(self):
        """Test getting ancestors for non-existent node."""
        target_node = {"title": "Nonexistent"}
        ancestors = SemanticTreeTraversal.get_ancestors(self.tree, target_node)

        # Non-existent node has no ancestors
        self.assertEqual(len(ancestors), 0)

    def test_get_siblings(self):
        """Test getting sibling nodes."""
        target_node = {"title": "Section 1"}
        siblings = SemanticTreeTraversal.get_siblings(self.tree, target_node)

        # Section 1's sibling is Section 2
        sibling_titles = [node["title"] for node in siblings]
        self.assertIn("Section 2", sibling_titles)
        self.assertEqual(len(siblings), 1)

    def test_get_siblings_single_child(self):
        """Test getting siblings when node is only child."""
        target_node = {"title": "Subsection 1.1"}
        siblings = SemanticTreeTraversal.get_siblings(self.tree, target_node)

        # Subsection 1.1 is only child, so no siblings
        self.assertEqual(len(siblings), 0)

    def test_get_siblings_not_found(self):
        """Test getting siblings for non-existent node."""
        target_node = {"title": "Nonexistent"}
        siblings = SemanticTreeTraversal.get_siblings(self.tree, target_node)

        # Non-existent node has no siblings
        self.assertEqual(len(siblings), 0)


if __name__ == "__main__":
    unittest.main()
