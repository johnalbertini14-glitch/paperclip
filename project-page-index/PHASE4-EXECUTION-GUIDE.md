# Phase 4: Execution Guide

**Status**: Tests implemented, ready to execute  
**Prerequisites**: Python 3.11 runtime  
**Estimated Duration**: 2-4 hours for full execution and analysis

---

## Pre-Execution Checklist

### Environment Setup

```bash
cd /paperclip/instances/default/workspaces/e5efa3c2-9c67-4617-8612-998ea68edfed/project-page-index/

# Verify Python 3.11 is available
python3.11 --version
# Expected: Python 3.11.x

# Create virtual environment
python3.11 -m venv .venv311
source .venv311/bin/activate

# Install dependencies
pip install --upgrade pip setuptools wheel
pip install -r requirements.txt
pip install pytest pytest-asyncio pytest-benchmark
```

### Verify Test Structure

```bash
# Check test files exist
ls -la tests/
# Expected: conftest.py, test_adapter.py, test_integration.py, 
#           test_performance.py, test_semantic_tree.py

# Check adapter code exists
ls -la src/
# Expected: __init__.py, adapter.py, mcp_server.py, 
#           semantic_tree.py, validators.py
```

---

## Execution Plan

### Phase 4.1: Unit Tests (10 min)

**Purpose**: Validate basic adapter functionality

```bash
pytest tests/test_adapter.py -v
```

**Success Criteria**:
- All tests pass
- No import errors
- Adapter initialization works

**If Fails**: Check imports and dependencies

---

### Phase 4.2: Semantic Tree Tests (10 min)

**Purpose**: Validate tree building and traversal

```bash
pytest tests/test_semantic_tree.py -v
```

**Success Criteria**:
- Tree structure correct
- Node relationships work
- Hierarchy preserved

**If Fails**: Debug tree builder logic

---

### Phase 4.3: Integration Tests (20 min)

**Purpose**: Full integration with real vault simulation

```bash
pytest tests/test_integration.py -v --tb=short
```

**Key Tests**:
- Vault initialization
- Document ingestion
- Query execution
- MCP server connectivity
- Error handling
- Security validation

**Success Criteria**:
- 15/15 integration tests pass
- All security tests pass (REVA-249)
- No exceptions in error recovery tests
- Real-world scenarios work

**Troubleshooting**:
- If vault tests fail: Check test_vault_path fixture
- If MCP tests fail: Verify MCP server initialization
- If security tests fail: Check validator implementation

---

### Phase 4.4: Performance Benchmarks (30 min)

**Purpose**: Measure performance and validate targets

```bash
# Run all performance tests
pytest tests/test_performance.py -v --tb=short

# Generate detailed performance report
pytest tests/test_performance.py -v --tb=short -s
```

**Performance Targets**:
| Metric | Target | Acceptable |
|--------|--------|-----------|
| Small vault load (10 docs) | < 5s | < 10s |
| Medium vault load (100 docs) | < 30s | < 60s |
| Large vault load (200+ docs) | < 60s | < 120s |
| Query latency (avg) | < 100ms | < 500ms |
| Query throughput | > 5 q/s | > 1 q/s |
| Memory stability (100 queries) | < 10MB increase | < 50MB increase |

**If Performance Below Target**:
1. Profile with `cProfile`: `python -m cProfile -s cumtime -m pytest tests/test_performance.py`
2. Check for:
   - Inefficient tree traversal
   - Memory leaks in query execution
   - Cache performance issues
   - I/O bottlenecks in vault loading
3. Optimize and re-run

---

### Phase 4.5: Memory and Scalability Tests (20 min)

**Purpose**: Verify memory safety and scalability

```bash
pytest tests/test_performance.py::TestMemoryUsage -v
pytest tests/test_performance.py::TestScalability -v
```

**What to Monitor**:
- Memory doesn't grow unbounded
- Deep hierarchies don't degrade performance
- Wide hierarchies handled efficiently
- Large result sets processed correctly

**Success Criteria**:
- Memory stable after 100+ queries
- No significant latency increase with depth/width
- Large results (100+) handled without errors

---

### Phase 4.6: Real Vault Testing (Optional, 30-60 min)

**Purpose**: Test with actual Albertini Brain vault

**Prerequisites**:
- Access to `~/Albertini Brain/` directory
- Vault contains real documents

**Execution**:

```python
from src.adapter import PageIndexAdapter

adapter = PageIndexAdapter(vault_path="~/Albertini Brain/")

# Load and verify
namespaces = adapter.get_namespaces()
print(f"Loaded {len(namespaces)} documents")

# Test queries on real content
test_queries = [
    "authentication",
    "deployment",
    "architecture",
    "API endpoints",
    "database schema"
]

for query in test_queries:
    results = adapter.query(query, limit=5)
    print(f"Query '{query}': {len(results)} results")
    for result in results[:2]:
        print(f"  - {result.get('heading', 'N/A')}")
```

**Success Criteria**:
- Vault loads completely
- Queries return relevant results
- Response times acceptable
- No errors on diverse document types

---

## Results Collection

### Performance Report Generation

```bash
# Create detailed performance report
pytest tests/test_performance.py -v --tb=short --co > test_collection.txt

# Capture output to file
pytest tests/ -v 2>&1 | tee test_results.log

# Count pass/fail
grep -E "PASSED|FAILED" test_results.log | sort | uniq -c
```

### Metrics to Collect

1. **Test Results**: Total tests, passed, failed, skipped
2. **Performance Data**: Latency percentiles, throughput, memory
3. **Coverage**: Which test categories passed/failed
4. **Error Summary**: Any failures and root causes

### Report Template

```
Phase 4 Execution Report
========================

Date: [timestamp]
Python Version: [3.11.x]
Environment: [VPS/local]

Test Results
------------
Unit Tests: X/X passed
Integration Tests: X/X passed
Performance Tests: X/X passed
Total: X/X passed

Performance Metrics
-------------------
Vault Loading:
  - Small (10 docs): X.XXs
  - Medium (100 docs): X.XXs
  - Large (200+ docs): X.XXs

Query Performance:
  - Average latency: XXms
  - P95 latency: XXms
  - P99 latency: XXms
  - Throughput: XX q/s

Memory Usage:
  - Vault footprint: XXMBMemory increase (100 queries): XXMBMB

Security Validation
-------------------
- ReDoS protection: PASSED
- Path traversal prevention: PASSED
- Workspace isolation: PASSED
- Error recovery: PASSED

Recommendations
---------------
[List any issues found and recommended fixes]
```

---

## Troubleshooting

### Common Issues

**Import Errors**
```
ModuleNotFoundError: No module named 'src'
```
Solution: Ensure `src/` directory exists with `__init__.py`

**Async Test Failures**
```
RuntimeError: Event loop is closed
```
Solution: Check pytest-asyncio version: `pip install pytest-asyncio==0.21.1`

**Performance Below Target**
1. Check if system is under load: `top`, `free -h`
2. Profile code: `python -m cProfile -s cumtime -m pytest tests/`
3. Check I/O: `iotop` while tests run

**Fixture Errors**
```
fixture 'adapter' not found
```
Solution: Verify `conftest.py` exists in `tests/` directory

---

## Next Steps After Phase 4

### If All Tests Pass ✅

1. **Collect metrics** and create performance report
2. **Deploy to production**:
   - Copy code to `/paperclip/.claude/platform-adapters-page-index/`
   - Configure MCP server settings
   - Update Paperclip initialization code
3. **Set up monitoring**:
   - Query latency metrics
   - Vault size and document count
   - Error rates and exceptions
4. **Create operational runbook**:
   - Deployment checklist
   - Health check procedures
   - Troubleshooting guide

### If Tests Fail ❌

1. **Identify root cause** from test output
2. **Fix issue** in adapter code
3. **Re-run tests** to verify fix
4. **Add regression test** if gap found
5. **Document fix** in commit message

### Phase 5: Optimization (If Needed)

If performance below target:
1. Profile bottlenecks
2. Optimize tree traversal
3. Improve caching strategy
4. Consider async I/O for vault loading
5. Re-benchmark after changes

---

## Success Criteria - Phase 4 Complete

✅ All 37 tests passing  
✅ Performance metrics within targets  
✅ Security validation complete (REVA-249)  
✅ Real vault testing successful (if available)  
✅ Performance report generated  
✅ Deployment-ready artifacts created  
✅ Documentation complete  

---

## Contact & Questions

**Implementation Owner**: Code Worker B  
**Test Location**: `/paperclip/instances/default/workspaces/e5efa3c2-9c67-4617-8612-998ea68edfed/project-page-index/`  
**Memory Context**: `memory/2026-04-25-phase4-test-implementation.md`

For blockers or questions, consult PHASE4-DEPLOYMENT-PLAN.md
