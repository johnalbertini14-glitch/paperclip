# PageIndex Semantic Tree Adapter

Document processing adapter for Paperclip platform providing vectorless reasoning-based RAG through semantic tree indices.

## Purpose

PageIndex provides an alternative to vector search for structured documents (e.g., Obsidian vaults) using hierarchical semantic tree indices instead of embeddings. Documents are transformed into TOC-like structures that preserve hierarchy for semantic traversal.

## Architecture

### Components

1. **Semantic Tree Index** - Transforms docs into hierarchical structure
2. **LLM Navigation** - Preserves document structure for semantic traversal
3. **MCP Integration** - Exposes semantic tree as MCP server
4. **Query Methods** - Structure-aware search preserving hierarchy

### Integration Pattern

- **Type**: Platform adapter plugin
- **Target Layer**: Document processing pipeline
- **Lifecycle Hooks**: Document ingestion, agent context enrichment
- **Configuration**: Feature flag toggle, vault path config

## Usage

### Configuration

```yaml
adapters:
  pageindex:
    enabled: true
    vault_path: "~/Albertini Brain/"
    mcp_server_enabled: true
    hierarchy_depth_limit: 10
```

### MCP Server

PageIndex exposes a semantic tree index as an MCP server for agent access.

```python
# Connect to PageIndex MCP server
client = MCPClient("page-index")
tree = await client.get_semantic_tree("vault-namespace")
results = await client.query(tree, "search query")
```

## Known Issues

- **Double Prefix Bug**: Routes unreachable due to `/api/vault/api/vault` concatenation
- **Route Ordering Bug**: Search endpoint shadowed by wildcard handler
- **Missing Auth**: Endpoints accept workspace_id as query parameter (needs auth validation)
- **ReDoS Risk**: User-controlled query passed to MongoDB regex (input validation needed)

See REVA-249 for security fixes required before production.

## Files

- `src/adapter.py` - Core adapter implementation
- `src/mcp_server.py` - MCP server integration
- `src/semantic_tree.py` - Semantic tree construction and traversal
- `tests/` - Test suite for adapter functionality

## Status

⚠️ **In Development** - Extracted from Signatiq (REVA-170), requires:
1. Security fixes per REVA-249
2. Integration with Paperclip lifecycle hooks
3. Test coverage validation
4. MCP server endpoint verification

## References

- [REVA-327 Install Pattern](../../REVA-327_install_pattern.md)
- [REVA-327 Feature Catalog](../../REVA-327_feature_catalog.md)
- [REVA-170 Original Implementation](REVA-170-original.md)
- [REVA-249 Security Audit](../../REVA-249-security.md)
