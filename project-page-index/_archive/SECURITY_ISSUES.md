# PageIndex Security Issues (REVA-249 Context)

This document catalogs known security issues from the original Signatiq implementation that must be fixed during Paperclip installation.

## Critical Issues

### 1. Missing Authentication

**Severity**: CRITICAL  
**Location**: All endpoints  
**Issue**: Endpoints accept `workspace_id` and `user_id` as plain query parameters without authentication validation

**Current Pattern**:
```python
@app.get("/vault/pages/{page_id}")
async def get_page(workspace_id: str, user_id: str, page_id: str):
    # No auth check - accepts any workspace_id/user_id
    pass
```

**Required Fix**: Implement proper JWT/session validation
```python
from fastapi.security import HTTPBearer

security = HTTPBearer()

@app.get("/vault/pages/{page_id}")
async def get_page(
    page_id: str,
    credentials: HTTPAuthorizationCredentials = Depends(security)
):
    # Validate JWT token and extract workspace/user
    workspace_id, user_id = await validate_and_extract_auth(credentials.credentials)
    pass
```

### 2. Route Double Prefix Bug

**Severity**: HIGH  
**Location**: Route definitions  
**Issue**: Routes unreachable due to concatenated prefixes creating `/api/vault/api/vault/pages/...`

**Current Pattern**:
```python
app.include_router(page_router, prefix="/api/vault")
# In page_router:
@router.get("/api/vault/pages/{page_id}")  # WRONG: duplicate prefix
```

**Required Fix**: Remove duplicate prefix from router
```python
@router.get("/pages/{page_id}")  # Prefix added by include_router
```

### 3. Route Ordering Bug

**Severity**: MEDIUM  
**Location**: Route handler ordering  
**Issue**: Generic `GET /{page_id}` route shadows `GET /search` endpoint making search dead

**Current Pattern**:
```python
@router.get("/{page_id}")  # Matches /search before search route is checked
async def get_page(page_id: str):
    pass

@router.get("/search")  # Never reached
async def search_pages(query: str):
    pass
```

**Required Fix**: Define specific routes before generic patterns
```python
@router.get("/search")  # Specific first
async def search_pages(query: str):
    pass

@router.get("/{page_id}")  # Generic last
async def get_page(page_id: str):
    pass
```

### 4. ReDoS Vulnerability in Query Parameter

**Severity**: CRITICAL  
**Location**: Search query handling  
**Issue**: User-controlled `query` parameter passed directly to MongoDB `$regex` without validation

**Current Pattern**:
```python
@router.get("/search")
async def search_pages(workspace_id: str, query: str):
    # Direct regex without validation allows ReDoS attacks
    results = await db.pages.find({
        "workspace_id": workspace_id,
        "content": {"$regex": query}  # Vulnerable!
    })
    return results
```

**Required Fix**: Validate and escape query parameters
```python
import re
from pymongo import errors

@router.get("/search")
async def search_pages(workspace_id: str, query: str):
    # Validate query length and escape special characters
    if len(query) > 1000:
        raise ValueError("Query too long")

    # Escape regex special characters
    escaped_query = re.escape(query)

    try:
        results = await db.pages.find({
            "workspace_id": workspace_id,
            "content": {"$regex": escaped_query, "$options": "i"}
        }).to_list(length=100)
    except errors.InvalidOperation as e:
        logger.error(f"Regex error: {e}")
        raise ValueError("Invalid search query")

    return results
```

## Medium Issues

### 5. Missing User/Workspace Scoping

**Severity**: MEDIUM  
**Location**: Database queries  
**Issue**: Some queries may not properly scope data by workspace/user

**Required Fix**: Add workspace validation to all queries
```python
async def validate_workspace_access(
    workspace_id: str,
    user_id: str,
    auth_token: str
) -> bool:
    """Verify user has access to workspace."""
    # Check user's workspace membership
    user_workspaces = await get_user_workspaces(user_id)
    return workspace_id in user_workspaces
```

### 6. Missing Input Validation

**Severity**: MEDIUM  
**Location**: Request handlers  
**Issue**: Page IDs, query strings, and other inputs not validated

**Required Fix**: Add Pydantic validation schemas
```python
from pydantic import BaseModel, Field, validator

class SearchQuery(BaseModel):
    workspace_id: str = Field(..., min_length=1, max_length=100)
    user_id: str = Field(..., min_length=1, max_length=100)
    query: str = Field(..., min_length=1, max_length=1000)

    @validator('query')
    def validate_query(cls, v):
        # Reject queries with suspicious patterns
        if any(suspicious in v for suspicious in ['$(', '{$', '<!--']):
            raise ValueError("Query contains suspicious patterns")
        return v
```

## Implementation Roadmap

### Phase 1: Authentication (CRITICAL)
- [ ] Implement JWT validation
- [ ] Replace query parameters with auth headers
- [ ] Add user context extraction

### Phase 2: Route Fixes (HIGH)
- [ ] Remove duplicate prefixes
- [ ] Fix route ordering
- [ ] Test all endpoints are reachable

### Phase 3: Input Validation (MEDIUM)
- [ ] Add Pydantic schemas
- [ ] Validate all inputs
- [ ] Implement query sanitization

### Phase 4: Scoping (MEDIUM)
- [ ] Add workspace validation
- [ ] Add user permission checks
- [ ] Audit all queries for proper scoping

## Testing Requirements

All security fixes must include:
- [ ] Unit tests for auth validation
- [ ] Integration tests with valid/invalid credentials
- [ ] Regex ReDoS tests with malicious queries
- [ ] Route accessibility tests
- [ ] Workspace scoping tests

## References

- REVA-327: Feature catalog with security context
- REVA-249: Original security audit findings
- REVA-326: Phase 1 installation requirements
