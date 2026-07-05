"""
Pytest configuration and fixtures for PageIndex tests.
"""

import pytest
import asyncio
import tempfile
import time
from pathlib import Path
from typing import AsyncGenerator, Generator
import pytest_asyncio

@pytest.fixture(scope="session")
def event_loop():
    """Create event loop for async tests."""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    yield loop
    loop.close()


@pytest.fixture
def test_vault_path() -> Generator[Path, None, None]:
    """Create temporary test vault with sample documents."""
    with tempfile.TemporaryDirectory() as tmpdir:
        vault_path = Path(tmpdir) / "test_vault"
        vault_path.mkdir(parents=True, exist_ok=True)

        # Create sample documents
        (vault_path / "api-reference.md").write_text("""# API Reference

## Authentication
Endpoints require JWT token in Authorization header.

### Login Endpoint
POST /api/auth/login
- Request: username, password
- Returns: JWT token with 24h expiry

### Logout Endpoint
POST /api/auth/logout
- Returns: success confirmation

## Users
User management endpoints with authentication.

### Get User
GET /api/users/{id}
- Returns: user details, email, created_at

### Update User
PATCH /api/users/{id}
- Updates user profile

### Delete User
DELETE /api/users/{id}
- Soft-deletes user account
""")

        (vault_path / "architecture.md").write_text("""# System Architecture

## Overview
Distributed system with microservices.

### Backend Services
- FastAPI service on port 8000
- PostgreSQL database
- Redis cache

### Frontend
- React 18 application
- Vite bundler
- TypeScript

## Database
PostgreSQL with Drizzle ORM for migrations.

### Schema
- users table with auth fields
- documents table with versioning
- sessions table for active sessions
""")

        (vault_path / "deployment.md").write_text("""# Deployment Guide

## Production Deployment
Deploying to AWS ECS cluster.

### Pre-Deployment Checklist
- All tests passing
- Code reviewed and approved
- Database migrations tested

### Deployment Steps
1. Build Docker image
2. Push to ECR
3. Update ECS task definition
4. Deploy to production
5. Monitor health checks

### Rollback Procedure
If deployment fails:
1. Revert to previous task definition
2. Check logs for errors
3. Notify team
""")

        yield vault_path


@pytest_asyncio.fixture
async def adapter(test_vault_path):
    """Create PageIndexAdapter instance with test vault."""
    from src.adapter import PageIndexAdapter

    config = {
        "vault_path": str(test_vault_path),
        "hierarchy_depth_limit": 10
    }
    adapter_instance = PageIndexAdapter(config)
    await adapter_instance.initialize()
    yield adapter_instance


@pytest_asyncio.fixture
async def mcp_server(adapter):
    """Create PageIndexMCPServer instance."""
    from src.mcp_server import PageIndexMCPServer

    server = PageIndexMCPServer(adapter)
    yield server


@pytest.fixture
def performance_monitor():
    """Monitor performance during tests."""
    class PerformanceMonitor:
        def __init__(self):
            self.metrics = {}

        def start(self, name: str):
            self.metrics[name] = {"start": time.time()}

        def stop(self, name: str):
            if name in self.metrics:
                self.metrics[name]["elapsed"] = time.time() - self.metrics[name]["start"]

        def get_elapsed(self, name: str) -> float:
            return self.metrics.get(name, {}).get("elapsed", 0.0)

    return PerformanceMonitor()


# Markers for test categorization
def pytest_configure(config):
    config.addinivalue_line("markers", "integration: integration tests with Paperclip")
    config.addinivalue_line("markers", "asyncio: async test using pytest-asyncio")
    config.addinivalue_line("markers", "performance: performance/benchmark tests")
    config.addinivalue_line("markers", "security: security/validation tests")
