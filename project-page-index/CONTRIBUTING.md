# Contributing to PageIndex

Thank you for contributing to PageIndex! This guide explains how to set up a development environment and contribute changes.

## Development Setup

### Prerequisites

- Python 3.8 or higher
- git

### Installation

Clone the repository and install dependencies:

```bash
git clone <repository-url>
cd project-page-index
make install-dev
```

Or manually:

```bash
pip install -r requirements.txt
pip install pytest pytest-asyncio pytest-cov black mypy pylint
```

## Development Workflow

### Running Tests

Run all tests:
```bash
make test
```

Run tests with coverage report:
```bash
make test-cov
```

Run tests with verbose output:
```bash
make test-verbose
```

Run specific test file:
```bash
python -m pytest tests/test_semantic_tree.py -v
```

Run tests matching a pattern:
```bash
python -m pytest tests/ -k "test_get_ancestors" -v
```

### Code Quality

Check code with pylint:
```bash
make lint
```

Format code with black:
```bash
make format
```

## Code Standards

### Quality Requirements

All code must meet these standards before submission:

- **Pylint Score**: 10.00/10 (perfect score)
- **Test Coverage**: 100% for new functions
- **Type Hints**: All functions properly typed
- **Docstrings**: All public functions documented
- **No Warnings**: Zero deprecation or code warnings

### Code Style

- Use black for formatting (line length: 100)
- Use lazy logging format (`%` style, not f-strings)
- Use specific exception types (not broad `Exception`)
- Follow PEP 8 conventions

### Testing Requirements

- All new functions must have tests
- Test files follow pattern: `test_<module>.py`
- Async tests use `pytest-asyncio` fixtures
- Edge cases must be covered (empty inputs, None values, boundaries)

## Commit Message Format

Format commits as follows:

```
<type>: <subject>

<optional body>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code refactoring
- `test`: Test additions/modifications
- `doc`: Documentation changes
- `chore`: Build/configuration changes

Example:
```
feat: Implement semantic search with embeddings

Add semantic_search query method supporting embedding-based document matching.
Includes 8 tests for relevance scoring and result ranking.
```

## Pull Request Process

1. Create a feature branch: `git checkout -b feature/description`
2. Make your changes
3. Run tests: `make test-cov`
4. Run linter: `make lint`
5. Format code: `make format`
6. Commit with proper message format
7. Push to remote: `git push origin feature/description`
8. Create pull request with summary of changes

## Testing Guidelines

### Unit Tests

Test individual functions in isolation:

```python
def test_my_function():
    result = my_function("input")
    assert result == "expected_output"
```

### Integration Tests

Test multiple components together:

```python
@pytest.mark.integration
async def test_adapter_with_semantic_tree(adapter, test_vault_path):
    tree = await adapter.get_tree("test_doc")
    assert tree is not None
    assert tree.title == "root"
```

### Edge Cases

Always test edge cases:

```python
def test_empty_input():
    result = my_function("")
    assert result == []

def test_none_input():
    result = my_function(None)
    assert result is None

def test_boundary_values():
    assert my_function(0) == 0
    assert my_function(100) == 100
```

## Documentation

### Docstring Format

Use clear, concise docstrings:

```python
def get_ancestors(tree: Dict, target_node: Dict) -> List[Dict]:
    """Get all ancestor nodes for a target node.
    
    Args:
        tree: The semantic tree root
        target_node: The node to find ancestors for
    
    Returns:
        List of ancestor nodes from root to target
    """
```

### Code Comments

- Only comment WHY something is done, not WHAT
- Avoid comments that become outdated
- Use type hints instead of type comments

## Performance Considerations

- Monitor latency with `make test-cov` for performance tests
- Use async/await for I/O operations
- Consider memory usage for large document collections
- Profile code if performance regressions occur

## Security Guidelines

- Validate all user inputs
- Use Pydantic models for input validation
- Prevent ReDoS attacks (dangerous pattern detection)
- Use specific exception types for clarity
- Never expose internal implementation details

## Getting Help

- Check [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) for API details
- Review [QUALITY_REPORT.md](QUALITY_REPORT.md) for code quality metrics
- Look at existing tests for usage examples
- Open an issue for questions or discussions

## Code Review

All changes undergo code review:

1. Functionality: Does it work as intended?
2. Tests: Are edge cases covered?
3. Documentation: Is it clear and complete?
4. Performance: Are there any regressions?
5. Security: Are inputs validated properly?

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.

---

Thank you for your contributions!
