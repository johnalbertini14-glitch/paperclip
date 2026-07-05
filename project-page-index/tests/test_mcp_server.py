"""Tests for PageIndex MCP Server."""
# pylint: disable=redefined-outer-name,protected-access,line-too-long

from unittest.mock import AsyncMock, MagicMock
import pytest
from src.mcp_server import PageIndexMCPServer
from src.adapter import PageIndexAdapter, SemanticNode, SearchResult


@pytest.fixture
def mock_adapter():
    """Create a mock adapter."""
    adapter = MagicMock(spec=PageIndexAdapter)
    return adapter


@pytest.fixture
def mcp_server(mock_adapter):
    """Create MCP server with mock adapter."""
    return PageIndexMCPServer(mock_adapter)


@pytest.fixture
def sample_semantic_node():
    """Create a sample semantic node tree."""
    child1 = SemanticNode(
        id="child1",
        title="Getting Started",
        content="How to get started",
        path=["Guide", "Getting Started"],
        level=2,
        metadata={"document_id": "guide.md"}
    )
    child2 = SemanticNode(
        id="child2",
        title="Advanced Topics",
        content="Advanced content",
        path=["Guide", "Advanced Topics"],
        level=2,
        metadata={"document_id": "guide.md"}
    )
    root = SemanticNode(
        id="root",
        title="Guide",
        content="Main guide",
        path=["Guide"],
        level=1,
        children=[child1, child2],
        metadata={"document_id": "guide.md"}
    )
    return root


class TestMCPServerInitialization:
    """Test MCP server initialization."""

    async def test_initialize_calls_adapter(self, mcp_server, mock_adapter):
        """Test that initialize calls adapter.initialize."""
        mock_adapter.initialize = AsyncMock()
        await mcp_server.initialize()
        mock_adapter.initialize.assert_called_once()

    def test_server_has_adapter(self, mcp_server, mock_adapter):
        """Test that server stores adapter reference."""
        assert mcp_server.adapter is mock_adapter


class TestGetSemanticTree:
    """Test get_semantic_tree method."""

    async def test_get_semantic_tree_returns_tree(self, mcp_server, mock_adapter, sample_semantic_node):
        """Test getting semantic tree for valid namespace."""
        mock_adapter.get_tree = AsyncMock(return_value=sample_semantic_node)

        result = await mcp_server.get_semantic_tree("guide.md")

        assert result is not None
        assert result["title"] == "Guide"
        assert result["id"] == "root"
        assert len(result["children"]) == 2

    async def test_get_semantic_tree_missing_namespace(self, mcp_server, mock_adapter):
        """Test getting semantic tree for non-existent namespace."""
        mock_adapter.get_tree = AsyncMock(return_value=None)

        result = await mcp_server.get_semantic_tree("missing.md")

        assert result is None

    async def test_get_semantic_tree_serializes_properly(self, mcp_server, mock_adapter, sample_semantic_node):
        """Test that tree is properly serialized."""
        mock_adapter.get_tree = AsyncMock(return_value=sample_semantic_node)

        result = await mcp_server.get_semantic_tree("guide.md")

        # Check structure
        assert "id" in result
        assert "title" in result
        assert "level" in result
        assert "path" in result
        assert "children" in result
        assert "metadata" in result


class TestQueryTree:
    """Test query_tree method."""

    async def test_query_tree_with_valid_params(self, mcp_server, mock_adapter):
        """Test querying tree with valid parameters."""
        search_result = SearchResult(
            node=SemanticNode("n1", "Match", "", ["Match"], 1),
            relevance_score=0.9,
            hierarchy_context=["Match"],
            matched_content="Match"
        )
        mock_adapter.query = AsyncMock(return_value=[search_result])

        results = await mcp_server.query_tree("doc.md", "search term")

        assert len(results) == 1
        assert results[0]["relevance_score"] == 0.9
        assert results[0]["matched_content"] == "Match"

    async def test_query_tree_with_limit(self, mcp_server, mock_adapter):
        """Test query respects limit parameter."""
        mock_adapter.query = AsyncMock(return_value=[])

        await mcp_server.query_tree("doc.md", "query", limit=5)

        # Verify limit was passed to adapter
        call_args = mock_adapter.query.call_args
        assert call_args.kwargs["limit"] == 5

    async def test_query_tree_with_method(self, mcp_server, mock_adapter):
        """Test query with specific method."""
        mock_adapter.query = AsyncMock(return_value=[])

        await mcp_server.query_tree("doc.md", "query", method="hierarchy_traversal")

        # Verify method was processed
        call_args = mock_adapter.query.call_args
        assert call_args.kwargs["method"].value == "hierarchy_traversal"

    async def test_query_tree_invalid_method_raises(self, mcp_server, mock_adapter):
        """Test that invalid method raises ValueError during validation."""
        mock_adapter.query = AsyncMock(return_value=[])

        with pytest.raises(ValueError, match="Invalid query parameters"):
            await mcp_server.query_tree("doc.md", "query", method="invalid_method")

    async def test_query_tree_invalid_params_raises(self, mcp_server, mock_adapter):
        """Test that invalid parameters raise ValueError."""
        with pytest.raises(ValueError):
            await mcp_server.query_tree("doc.md", "", limit=-1)

    async def test_query_tree_empty_results(self, mcp_server, mock_adapter):
        """Test query with no results."""
        mock_adapter.query = AsyncMock(return_value=[])

        results = await mcp_server.query_tree("doc.md", "query")

        assert results == []


class TestListDocuments:
    """Test list_documents method."""

    async def test_list_documents_returns_namespaces(self, mcp_server, mock_adapter):
        """Test listing documents."""
        mock_adapter.list_namespaces = AsyncMock(return_value=["doc1.md", "doc2.md", "doc3.md"])

        result = await mcp_server.list_documents()

        assert result == ["doc1.md", "doc2.md", "doc3.md"]

    async def test_list_documents_empty(self, mcp_server, mock_adapter):
        """Test listing when no documents."""
        mock_adapter.list_namespaces = AsyncMock(return_value=[])

        result = await mcp_server.list_documents()

        assert result == []


class TestGetDocumentSection:
    """Test get_document_section method."""

    async def test_get_document_section_with_hierarchy(self, mcp_server, mock_adapter, sample_semantic_node):
        """Test getting document section with hierarchy."""
        mock_adapter.get_tree = AsyncMock(return_value=sample_semantic_node)

        result = await mcp_server.get_document_section("guide.md", "child1", include_hierarchy=True)

        assert result is not None
        assert "node" in result
        assert "metadata" in result
        assert "ancestry" in result

    async def test_get_document_section_without_hierarchy(self, mcp_server, mock_adapter, sample_semantic_node):
        """Test getting document section without hierarchy."""
        mock_adapter.get_tree = AsyncMock(return_value=sample_semantic_node)

        result = await mcp_server.get_document_section("guide.md", "child1", include_hierarchy=False)

        assert result is not None
        assert "node" in result
        assert "metadata" in result
        assert "ancestry" not in result

    async def test_get_document_section_missing_namespace(self, mcp_server, mock_adapter):
        """Test getting section from non-existent namespace."""
        mock_adapter.get_tree = AsyncMock(return_value=None)

        result = await mcp_server.get_document_section("missing.md", "node1")

        assert result is None

    async def test_get_document_section_missing_node(self, mcp_server, mock_adapter, sample_semantic_node):
        """Test getting non-existent node."""
        mock_adapter.get_tree = AsyncMock(return_value=sample_semantic_node)

        result = await mcp_server.get_document_section("guide.md", "nonexistent")

        assert result is None


class TestFindNodeById:
    """Test _find_node_by_id method."""

    def test_find_node_root(self, mcp_server, sample_semantic_node):
        """Test finding root node."""
        node = mcp_server._find_node_by_id(sample_semantic_node, "root")

        assert node is not None
        assert node.title == "Guide"

    def test_find_node_child(self, mcp_server, sample_semantic_node):
        """Test finding child node."""
        node = mcp_server._find_node_by_id(sample_semantic_node, "child1")

        assert node is not None
        assert node.title == "Getting Started"

    def test_find_node_not_found(self, mcp_server, sample_semantic_node):
        """Test finding non-existent node."""
        node = mcp_server._find_node_by_id(sample_semantic_node, "nonexistent")

        assert node is None

    def test_find_node_deep_tree(self, mcp_server):
        """Test finding node in deep tree."""
        level3 = SemanticNode("l3", "Level3", "", ["root", "l2", "l3"], 3)
        level2 = SemanticNode("l2", "Level2", "", ["root", "l2"], 2, children=[level3])
        level1 = SemanticNode("l1", "Level1", "", ["root", "l1"], 1, children=[level2])
        root = SemanticNode("root", "Root", "", [], 0, children=[level1])

        node = mcp_server._find_node_by_id(root, "l3")

        assert node is not None
        assert node.title == "Level3"


class TestGetNodeAncestry:
    """Test _get_node_ancestry method."""

    async def test_get_node_ancestry_root(self, mcp_server, sample_semantic_node):
        """Test getting ancestry for root node."""
        ancestry = await mcp_server._get_node_ancestry(sample_semantic_node, "root")

        assert len(ancestry) == 1
        assert ancestry[0]["title"] == "Guide"

    async def test_get_node_ancestry_child(self, mcp_server, sample_semantic_node):
        """Test getting ancestry for child node."""
        ancestry = await mcp_server._get_node_ancestry(sample_semantic_node, "child1")

        assert len(ancestry) == 2
        assert ancestry[0]["title"] == "Guide"
        assert ancestry[1]["title"] == "Getting Started"

    async def test_get_node_ancestry_not_found(self, mcp_server, sample_semantic_node):
        """Test getting ancestry for non-existent node."""
        ancestry = await mcp_server._get_node_ancestry(sample_semantic_node, "nonexistent")

        assert ancestry == []


class TestSerializeTree:
    """Test _serialize_tree method."""

    async def test_serialize_tree_simple_node(self, mcp_server):
        """Test serializing simple node."""
        node = SemanticNode("n1", "Title", "Content", ["path"], 1)

        serialized = await mcp_server._serialize_tree(node)

        assert serialized["id"] == "n1"
        assert serialized["title"] == "Title"
        assert serialized["level"] == 1
        assert serialized["path"] == ["path"]
        assert serialized["children"] == []

    async def test_serialize_tree_with_children(self, mcp_server):
        """Test serializing tree with children."""
        child = SemanticNode("c1", "Child", "", ["path", "child"], 2)
        parent = SemanticNode("p1", "Parent", "", ["path"], 1, children=[child])

        serialized = await mcp_server._serialize_tree(parent)

        assert len(serialized["children"]) == 1
        assert serialized["children"][0]["title"] == "Child"

    async def test_serialize_tree_metadata(self, mcp_server):
        """Test that metadata is included in serialization."""
        node = SemanticNode(
            "n1", "Title", "", [], 0,
            metadata={"key": "value"}
        )

        serialized = await mcp_server._serialize_tree(node)

        assert "metadata" in serialized
        assert serialized["metadata"]["key"] == "value"


class TestSerializeResult:
    """Test _serialize_result method."""

    async def test_serialize_result(self, mcp_server):
        """Test serializing search result."""
        node = SemanticNode("n1", "Found", "", ["path"], 1)
        result = SearchResult(
            node=node,
            relevance_score=0.85,
            hierarchy_context=["path"],
            matched_content="Found"
        )

        serialized = await mcp_server._serialize_result(result)

        assert serialized["relevance_score"] == 0.85
        assert serialized["hierarchy_context"] == ["path"]
        assert serialized["matched_content"] == "Found"
        assert serialized["node"]["title"] == "Found"


class TestMCPServerErrorHandling:
    """Test error handling in MCP server."""

    async def test_query_validation_error(self, mcp_server):
        """Test that invalid query parameters raise error."""
        with pytest.raises(ValueError):
            await mcp_server.query_tree("doc.md", "query", limit=-1)

    async def test_query_method_conversion_error_handling(self, mcp_server, mock_adapter):
        """Test that invalid method raises during validation."""
        mock_adapter.query = AsyncMock(return_value=[])

        # Invalid method is rejected by validator
        with pytest.raises(ValueError, match="Invalid query parameters"):
            await mcp_server.query_tree("doc.md", "query", method="invalid")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
