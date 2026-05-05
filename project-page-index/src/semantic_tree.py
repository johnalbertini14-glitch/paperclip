"""
Semantic Tree construction and traversal utilities.

Transforms documents into hierarchical structures preserving semantic relationships.
"""

from typing import List, Dict, Optional, Any
import re
from dataclasses import dataclass
import logging

logger = logging.getLogger(__name__)


@dataclass
class HeadingMatch:
    """Matched heading with level and position."""
    level: int
    title: str
    position: int
    content_start: int
    content_end: Optional[int] = None


class SemanticTreeBuilder:
    """Builds semantic trees from document content."""

    def __init__(self, max_heading_level: int = 6):
        """Initialize tree builder.

        Args:
            max_heading_level: Maximum heading level to recognize (1-6 for markdown)
        """
        self.max_heading_level = max_heading_level

    def parse_markdown_headings(self, content: str) -> List[HeadingMatch]:
        """
        Extract heading hierarchy from markdown content.

        Returns headings with levels (1-6) and positions.
        """
        headings = []
        lines = content.split('\n')
        current_pos = 0

        # Pattern for markdown headings: # Title, ## Title, etc.
        heading_pattern = r'^(#{1,6})\s+(.+)$'

        for line_idx, line in enumerate(lines):
            match = re.match(heading_pattern, line)
            if match:
                level = len(match.group(1))
                title = match.group(2)

                if level <= self.max_heading_level:
                    headings.append(HeadingMatch(
                        level=level,
                        title=title,
                        position=line_idx,
                        content_start=current_pos
                    ))

            current_pos += len(line) + 1  # +1 for newline

        # Calculate content ranges
        for i, heading in enumerate(headings):
            if i + 1 < len(headings):
                heading.content_end = headings[i + 1].content_start
            else:
                heading.content_end = len(content)

        return headings

    def extract_section_content(
        self,
        content: str,
        start: int,
        end: int
    ) -> str:
        """Extract content between positions."""
        return content[start:end].strip()

    def build_hierarchy(self, headings: List[HeadingMatch]) -> Dict[str, Any]:
        """
        Build hierarchical structure from flat list of headings.

        Creates parent-child relationships based on heading levels.
        """
        if not headings:
            return {"root": None, "children": []}

        stack = []
        root_node = {"title": "root", "level": 0, "children": []}

        for heading in headings:
            node = {
                "title": heading.title,
                "level": heading.level,
                "position": heading.position,
                "content_range": (heading.content_start, heading.content_end),
                "children": []
            }

            # Pop stack until we find appropriate parent
            while stack and stack[-1]["level"] >= heading.level:
                stack.pop()

            if stack:
                stack[-1]["children"].append(node)
            else:
                root_node["children"].append(node)

            stack.append(node)

        return root_node

    def build_tree(self, document_id: str, content: str) -> Dict[str, Any]:
        """
        Build complete semantic tree from document.

        Returns hierarchical structure with headings as nodes.
        """
        headings = self.parse_markdown_headings(content)
        hierarchy = self.build_hierarchy(headings)

        return {
            "document_id": document_id,
            "tree": hierarchy,
            "headings_count": len(headings),
            "max_depth": self._calculate_max_depth(hierarchy)
        }

    def _calculate_max_depth(self, node: Dict, current_depth: int = 0) -> int:
        """Calculate maximum depth in hierarchy."""
        if not node.get("children"):
            return current_depth

        return max(
            self._calculate_max_depth(child, current_depth + 1)
            for child in node["children"]
        )


class SemanticTreeTraversal:
    """Traversal utilities for semantic trees."""

    @staticmethod
    def flatten_tree(node: Dict, include_root: bool = False) -> List[Dict]:
        """
        Flatten tree into list of nodes.

        Useful for sequential processing or search.
        """
        result = []

        if include_root and node.get("title") != "root":
            result.append(node)

        for child in node.get("children", []):
            result.extend(SemanticTreeTraversal.flatten_tree(child, True))

        return result

    @staticmethod
    def find_node_by_title(
        node: Dict,
        title: str,
        exact: bool = True
    ) -> Optional[Dict]:
        """Find node by title."""
        if exact:
            if node.get("title") == title:
                return node
        else:
            if title.lower() in node.get("title", "").lower():
                return node

        for child in node.get("children", []):
            result = SemanticTreeTraversal.find_node_by_title(child, title, exact)
            if result:
                return result

        return None

    @staticmethod
    def get_ancestors(tree: Dict, target_node: Dict) -> List[Dict]:
        """Get all ancestor nodes for a target node."""
        ancestors = []

        def find_path(node, target, path):
            if node.get("title") == target.get("title"):
                ancestors.extend(path)
                return True
            for child in node.get("children", []):
                if find_path(child, target, path + [node]):
                    return True
            return False

        find_path(tree, target_node, [])
        return ancestors

    @staticmethod
    def get_siblings(tree: Dict, target_node: Dict) -> List[Dict]:
        """Get sibling nodes at same level."""
        siblings = []

        def find_siblings(node):
            children = node.get("children", [])
            for child in children:
                if child.get("title") == target_node.get("title"):
                    siblings.extend([
                        c for c in children
                        if c.get("title") != target_node.get("title")
                    ])
                    return True
            for child in children:
                if find_siblings(child):
                    return True
            return False

        find_siblings(tree)
        return siblings

    @staticmethod
    def get_subtree(node: Dict, max_depth: int = 3, current_depth: int = 0) -> Dict:
        """Get subtree up to maximum depth."""
        if current_depth >= max_depth:
            return {**node, "children": []}

        return {
            **node,
            "children": [
                SemanticTreeTraversal.get_subtree(child, max_depth, current_depth + 1)
                for child in node.get("children", [])
            ]
        }
