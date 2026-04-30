# PageIndex Integration Examples

Examples showing how to integrate PageIndex into Paperclip and other applications.

## Files

### paperclip-integration.py

Complete integration example showing:

1. **Initialization** - Setting up PageIndexAdapter and PageIndexMCPServer
2. **Lifecycle Hooks** - Handling document ingestion and deletion
3. **Agent Context Enrichment** - Providing relevant document sections to agents
4. **MCP Tools** - Exposing PageIndex functionality through MCP protocol

#### Key Components

- **PaperclipPageIndexIntegration** - Integration layer managing adapter and server
- **Lifecycle hooks** - `on_document_ingested()`, `on_document_deleted()`
- **Context enrichment** - `enrich_agent_context()` for agent use
- **MCP tools** - `PageIndexMCPTools` wrapping async operations

#### Running the Example

```bash
python examples/paperclip-integration.py
```

This runs `example_paperclip_usage()` which demonstrates:
- Initializing PageIndex
- Simulating document ingestion
- Enriching agent context
- Registering MCP tools
- Graceful shutdown

#### Integration Pattern

The example shows how Paperclip would integrate PageIndex:

1. Load adapter from configuration
2. Register lifecycle hooks for document events
3. Expose MCP tools to agents
4. Use context enrichment for agent queries

#### Configuration

```python
config = {
    "vault_path": "~/Albertini Brain/",
    "hierarchy_depth_limit": 10,
    "mcp_server_enabled": True,
    "mcp_server_port": 8001
}
```

#### Output

```
1. Initializing PageIndex...
✅ PageIndex initialized

2. Simulating document ingestion...
✅ Indexed document: api-design.md

3. Enriching agent context...
Found 0 relevant sections

4. Registering MCP tools...
Available MCP tools:
  - get_semantic_tree(namespace)
  - query_tree(namespace, query, method, limit)
  - list_documents()
  - get_document_section(namespace, node_id, include_hierarchy)

5. Shutting down...
✅ PageIndex shut down cleanly
```

## Next Steps

After running the example:

1. **Understand the flow** - Read through `paperclip-integration.py` comments
2. **Explore the API** - Check [IMPLEMENTATION_GUIDE.md](../IMPLEMENTATION_GUIDE.md)
3. **Review lifecycle hooks** - See how Paperclip events map to PageIndex operations
4. **Customize for your needs** - Adapt the integration pattern for your application

## Integration Checklist

When integrating PageIndex into your application:

- [ ] Configure vault path to your document location
- [ ] Set hierarchy depth limit based on your document structure
- [ ] Initialize adapter with configuration
- [ ] Register lifecycle hooks for document events
- [ ] Expose MCP tools to your agents/applications
- [ ] Test with sample documents
- [ ] Monitor performance with large document collections
- [ ] Set up error handling and logging

## See Also

- [README.md](../README.md) - Project overview
- [IMPLEMENTATION_GUIDE.md](../IMPLEMENTATION_GUIDE.md) - API reference
- [INSTALLATION.md](../INSTALLATION.md) - Installation and setup guide
