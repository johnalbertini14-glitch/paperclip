# PageIndex Implementation & Quality Guide

## Overview

This document covers the PageIndex semantic tree adapter implementation, code quality improvements, and API documentation for agents using the system.

## Architecture

### Core Components

1. **SemanticTreeBuilder** (`src/semantic_tree.py`)
   - Parses markdown documents into hierarchical structures
   - Preserves semantic relationships through heading levels
   - Handles content extraction and range calculation

2. **SemanticTreeTraversal** (`src/semantic_tree.py`)
   - Tree navigation and search utilities
   - Node hierarchy traversal (flatten, ancestors, siblings)
   - Content extraction with context

3. **PageIndexAdapter** (`src/adapter.py`)
   - Document vault management
   - Semantic tree building and caching
   - Query execution with multiple strategies

4. **PageIndexMCPServer** (`src/mcp_server.py`)
   - MCP protocol integration
   - Tool schema definition
   - Agent-facing API

### Data Models

**SemanticNode**
```python
@dataclass
class SemanticNode:
    id: str                      # Unique node identifier
    title: str                   # Heading text
    content: str                 # Section content
    path: List[str]              # Hierarchical path
    level: int                   # Heading level (1-6)
    children: List[SemanticNode] # Child nodes
    metadata: Dict[str, Any]     # Custom metadata
```

**SearchResult**
```python
@dataclass
class SearchResult:
    node: SemanticNode          # Matching node
    relevance_score: float      # Match quality (0-1)
    hierarchy_context: List[str] # Ancestor path
    matched_content: str        # Content snippet
```

## API Reference

### Tree Navigation Methods

#### `get_ancestors(tree, target_node) -> List[Dict]`
Retrieve all ancestor nodes for a target node, including the root.

**Parameters:**
- `tree: Dict` - The semantic tree root
- `target_node: Dict` - The node to find ancestors for

**Returns:** List of ancestor nodes from root to target

**Example:**
```python
target = {"title": "Subsection 1.1"}
ancestors = SemanticTreeTraversal.get_ancestors(tree, target)
# Returns: [root_node, section_node, subsection_node]
```

#### `get_siblings(tree, target_node) -> List[Dict]`
Retrieve sibling nodes at the same hierarchy level.

**Parameters:**
- `tree: Dict` - The semantic tree root
- `target_node: Dict` - The node to find siblings for

**Returns:** List of sibling nodes (excluding target)

**Example:**
```python
target = {"title": "Section 1"}
siblings = SemanticTreeTraversal.get_siblings(tree, target)
# Returns: [section_2, section_3, ...]
```

#### `flatten_tree(node, include_root=False) -> List[Dict]`
Convert tree to flat list for sequential processing.

**Parameters:**
- `node: Dict` - Starting node
- `include_root: bool` - Include the root node (default: False)

**Returns:** Flat list of all nodes

#### `find_node_by_title(node, title, exact=True) -> Optional[Dict]`
Search for node by title.

**Parameters:**
- `node: Dict` - Starting search node
- `title: str` - Title to search for
- `exact: bool` - Exact match or substring (default: True)

**Returns:** Matching node or None

#### `get_subtree(node, max_depth=3) -> Dict`
Extract subtree limited by depth.

**Parameters:**
- `node: Dict` - Root of subtree
- `max_depth: int` - Maximum depth (default: 3)

**Returns:** Subtree with depth limit applied

## Code Quality Standards

### Pylint Score: 10.00/10

The codebase meets the highest quality standards:
- ✅ No deprecation warnings
- ✅ No unused imports or variables
- ✅ Proper exception handling with exception chaining
- ✅ Lazy logging format (% style, not f-strings)
- ✅ Specific exception types (not broad Exception)

### Test Coverage: 52/52 Tests Passing

**Coverage breakdown:**
- Adapter tests: 6/6 ✅
- Integration tests: 10/10 ✅
- Performance tests: 13/13 ✅
- Semantic tree tests: 16/16 ✅
- Tree traversal tests: 7/7 ✅

New functions fully tested:
- `get_ancestors`: 3 test cases (basic, root, not-found)
- `get_siblings`: 3 test cases (basic, single-child, not-found)

### Pydantic v2 Migration

All validators upgraded to Pydantic v2 syntax:
- `@validator` → `@field_validator`
- `class Config` → `model_config = ConfigDict(...)`

## Implementation Notes

### Semantic Tree Structure

Trees are hierarchical dictionaries:
```python
{
    "title": "Section Title",
    "level": 1,
    "position": 5,
    "content_range": (100, 500),
    "children": [
        {
            "title": "Subsection",
            "level": 2,
            "position": 10,
            "content_range": (120, 300),
            "children": []
        }
    ]
}
```

### Query Methods

Supported query methods in `QueryMethod` enum:
- `STRUCTURE_AWARE` (default) - Title-based matching with hierarchy context
- `SEMANTIC_SEARCH` (reserved) - Future: embedding-based search
- `HIERARCHY_TRAVERSAL` (reserved) - Future: pattern-based traversal

Currently, all methods use structure-aware search. Future implementations will add specialized strategies.

### Error Handling

The system uses specific exception types:
- `OSError` - File system errors (vault loading)
- `ValidationError` - Pydantic model validation
- `ValueError` - Query parameter validation

All exceptions are properly chained with `from e` for debugging.

## Performance Characteristics

**Typical latency (on test data):**
- Small vault (100 files): <100ms load time
- Medium vault (1000 files): <500ms load time
- Large vault (10000 files): <2s load time
- Query execution: <50ms average

**Memory usage:**
- Stable across query operations
- LRU cache with automatic eviction
- No memory leaks detected

## Future Enhancements

Implemented TODO functions (now complete):
- ✅ `get_ancestors()` - Get ancestor chain for node
- ✅ `get_siblings()` - Get sibling nodes at same level

Planned (reserved for future):
- Semantic search with embeddings
- Pattern-based hierarchy traversal
- Advanced caching strategies
- Multi-language support

## Support & Debugging

For issues with the PageIndex system:

1. **Check vault path**: Ensure `vault_path` config points to valid directory
2. **Verify permissions**: Confirm file read access to vault
3. **Validate markdown**: Ensure documents follow markdown heading structure
4. **Review logs**: Check adapter initialization logs for errors
5. **Run tests**: Execute test suite to verify functionality

## Related Issues

- **REVA-516** - Original PageIndex installation
- **REVA-1113** - Pydantic v2 deprecation fixes
- **REVA-1118** - Code quality refactor (10.00/10 pylint)
- **REVA-1124** - Test coverage for new functions
