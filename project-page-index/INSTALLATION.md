# PageIndex Installation Guide

Instructions for installing PageIndex semantic tree adapter into Paperclip unified-agent-system.

## Installation Target

- **Base Path**: `unified-agent-system/platform-adapters/`
- **Component**: `page-index/`
- **Integration Pattern**: Hybrid Approach (Option C) from REVA-327

## Prerequisites

- Paperclip runtime environment
- Python 3.8+
- Agent lifecycle hook support
- MCP server capability (optional but recommended)

## Installation Steps

### Step 1: Copy Adapter Files

```bash
cp -r platform-adapters/page-index/ \
      /path/to/unified-agent-system/platform-adapters/
```

### Step 2: Install Dependencies

```bash
cd /path/to/unified-agent-system/platform-adapters/page-index/
pip install -r requirements.txt
```

### Step 3: Configure Agent Integration

Add PageIndex to agent configuration:

```yaml
# In agent_config.yaml or similar
adapters:
  page-index:
    enabled: true
    vault_path: "~/Albertini Brain/"
    hierarchy_depth_limit: 10
    mcp_server_enabled: true
    mcp_server_port: 8001
```

### Step 4: Register Lifecycle Hooks

PageIndex should be integrated with agent lifecycle:

```python
# In agent initialization code
from platform_adapters.page_index.src.adapter import PageIndexAdapter
from platform_adapters.page_index.src.mcp_server import PageIndexMCPServer

async def setup_page_index_adapter(agent_config):
    """Initialize PageIndex adapter for agent."""
    adapter_config = agent_config.get("adapters", {}).get("page-index", {})

    if not adapter_config.get("enabled"):
        return None

    # Create adapter instance
    adapter = PageIndexAdapter(adapter_config)
    await adapter.initialize()

    # Optionally start MCP server
    if adapter_config.get("mcp_server_enabled"):
        mcp_server = PageIndexMCPServer(adapter)
        await mcp_server.initialize()
        return mcp_server

    return adapter

# Register hook
agent.register_lifecycle_hook("setup", setup_page_index_adapter)
```

### Step 5: Test Integration

```bash
# Run adapter tests
python -m pytest tests/test_adapter.py -v

# Run semantic tree tests
python -m pytest tests/test_semantic_tree.py -v

# Test MCP server connectivity (if enabled)
# curl http://localhost:8001/health
```

## Configuration

### Minimal Configuration

```yaml
adapters:
  page-index:
    enabled: true
```

### Full Configuration

```yaml
adapters:
  page-index:
    enabled: true
    vault_path: "~/Albertini Brain/"
    hierarchy_depth_limit: 10
    mcp_server_enabled: true
    mcp_server_port: 8001
    mcp_server_host: "localhost"
    cache_enabled: true
    cache_ttl_seconds: 3600
    max_document_size_bytes: 10485760  # 10MB
```

## Integration Points

### 1. Document Ingestion Pipeline

PageIndex should integrate with document ingestion:

```python
async def on_document_ingested(doc_id: str, content: str, metadata: Dict):
    """Hook: Document added to vault."""
    tree = await adapter.build_semantic_tree(doc_id, content, metadata)
    # Index in semantic tree
```

### 2. Agent Context Enrichment

When agents need document context:

```python
async def get_relevant_documents(agent_id: str, query: str) -> List[Dict]:
    """Retrieve relevant sections from PageIndex."""
    results = await adapter.query(
        namespace=f"agent_{agent_id}",
        query=query,
        limit=10
    )
    return results
```

### 3. MCP Tool Integration

Expose PageIndex as MCP tools:

```python
# In agent prompt or tool registry
mcp_tools = [
    {
        "name": "search_vault",
        "description": "Search document vault using PageIndex",
        "function": mcp_server.query_tree
    },
    {
        "name": "get_document_tree",
        "description": "Get semantic tree structure",
        "function": mcp_server.get_semantic_tree
    }
]
```

## Security Integration

✅ **All security requirements implemented** (REVA-249)

All security requirements are implemented and tested:
1. ✅ Input validation via Pydantic validators
2. ✅ Query injection prevention (ReDoS protection)
3. ✅ Field validation with min/max constraints
4. ✅ Error handling with specific exception types
5. ✅ Comprehensive security test coverage (26 tests)

See SECURITY_ISSUES.md and QUALITY_REPORT.md for implementation details.

## Verification Checklist

- [ ] Files installed in correct directory
- [ ] Dependencies installed
- [ ] Configuration loaded without errors
- [ ] Tests pass (test_adapter.py, test_semantic_tree.py)
- [ ] Adapter initializes without errors
- [ ] Vault loads successfully
- [ ] First document indexed correctly
- [ ] Query returns expected results
- [ ] MCP server responds to requests (if enabled)
- [ ] Security fixes verified (REVA-249)

## Troubleshooting

### Vault Path Not Found

```python
# Check configuration
if not os.path.exists(adapter.vault_path):
    raise FileNotFoundError(f"Vault path not found: {adapter.vault_path}")
```

### Semantic Tree Build Fails

Check that documents are valid markdown with proper heading structure.

### MCP Server Won't Start

Verify port is available and no other service is bound:
```bash
netstat -an | grep 8001
```

### Query Returns No Results

- Verify documents are indexed (call `list_documents()`)
- Check vault_path configuration
- Verify query string is valid

## Next Steps

After installation:

1. **Validate** - Run full test suite
2. **Benchmark** - Test with real vault data
3. **Monitor** - Track performance metrics
4. **Iterate** - Refine tree building algorithm based on results
5. **Document** - Create usage guide for agents

## References

- [README.md](README.md) - Overview and status
- [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Complete API reference and architecture
- [QUALITY_REPORT.md](QUALITY_REPORT.md) - Quality metrics and improvements
- [SECURITY_ISSUES.md](SECURITY_ISSUES.md) - Security implementation details
- [REVA-327 Install Pattern](../../REVA-327_install_pattern.md)
- [REVA-327 Feature Catalog](../../REVA-327_feature_catalog.md)
- [REVA-170 Original Implementation](REVA-170-original.md)
