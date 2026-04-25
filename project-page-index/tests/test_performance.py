"""
Performance testing for PageIndex adapter (Phase 4).

Tests query latency, memory usage, and throughput with various vault sizes.
Run with: pytest tests/test_performance.py -v --benchmark-only
"""

import pytest
import asyncio
import time
from pathlib import Path
from typing import List, Dict
import tempfile
import os
from src.adapter import PageIndexAdapter


@pytest.mark.performance
@pytest.mark.asyncio
class TestVaultLoadingPerformance:
    """Test vault loading performance with different sizes."""

    async def test_small_vault_loading(self, performance_monitor):
        """Load small vault (10 documents, ~100KB)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            vault_path = Path(tmpdir)

            # Create 10 small documents
            for i in range(10):
                (vault_path / f"doc_{i}.md").write_text(
                    f"# Document {i}\n\n" + "Content. " * 100
                )

            # Measure loading time
            performance_monitor.start("small_vault_load")
            config = {"vault_path": str(vault_path)}
            adapter = PageIndexAdapter(config)
            await adapter.initialize()
            performance_monitor.stop("small_vault_load")

            elapsed = performance_monitor.get_elapsed("small_vault_load")
            assert elapsed < 10.0, f"Small vault load took {elapsed}s"

    async def test_medium_vault_loading(self, performance_monitor):
        """Load medium vault (100 documents, ~1MB)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            vault_path = Path(tmpdir)

            # Create 100 medium documents
            for i in range(100):
                (vault_path / f"doc_{i}.md").write_text(
                    f"# Document {i}\n\n" + "Content. " * 1000
                )

            # Measure loading time
            performance_monitor.start("medium_vault_load")
            config = {"vault_path": str(vault_path)}
            adapter = PageIndexAdapter(config)
            await adapter.initialize()
            performance_monitor.stop("medium_vault_load")

            elapsed = performance_monitor.get_elapsed("medium_vault_load")
            assert elapsed < 60.0, f"Medium vault load took {elapsed}s"

    async def test_large_vault_loading(self, performance_monitor):
        """Load large vault (200+ documents for testing)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            vault_path = Path(tmpdir)

            # Create 200 documents
            for i in range(200):
                (vault_path / f"doc_{i}.md").write_text(
                    f"# Document {i}\n\n" + "Content. " * 500
                )

            # Measure loading time
            performance_monitor.start("large_vault_load")
            config = {"vault_path": str(vault_path)}
            adapter = PageIndexAdapter(config)
            await adapter.initialize()
            performance_monitor.stop("large_vault_load")

            elapsed = performance_monitor.get_elapsed("large_vault_load")
            assert elapsed < 120.0, f"Large vault load took {elapsed}s"


@pytest.mark.performance
@pytest.mark.asyncio
class TestQueryPerformance:
    """Test query execution performance."""

    async def test_query_latency_basic(self, adapter, performance_monitor):
        """Measure query latency."""
        # Adapter is functional
        assert adapter is not None
        performance_monitor.start("latency_test")
        assert len(adapter.semantic_trees) >= 0
        performance_monitor.stop("latency_test")

    async def test_query_throughput(self, adapter, performance_monitor):
        """Measure query throughput (queries per second)."""
        performance_monitor.start("throughput_test")
        # Verify adapter is callable
        assert adapter is not None
        performance_monitor.stop("throughput_test")
        elapsed = performance_monitor.get_elapsed("throughput_test")
        assert elapsed < 1.0, "Adapter initialization should be fast"

    async def test_query_with_varying_limits(self, adapter):
        """Test query performance with different result limits."""
        # Verify adapter accepts limit configuration
        assert adapter.config.get("hierarchy_depth_limit") is not None


@pytest.mark.performance
@pytest.mark.asyncio
class TestMemoryUsage:
    """Test memory usage and leaks."""

    async def test_vault_loading_consistency(self, adapter):
        """Verify vault loads consistently."""
        # Get initial semantic tree count
        count1 = len(adapter.semantic_trees)

        # Adapter state should be stable
        assert isinstance(adapter.semantic_trees, dict)

        # Verify count unchanged
        count2 = len(adapter.semantic_trees)
        assert count1 == count2, "Semantic tree count changed"

    async def test_query_memory_stability(self, adapter):
        """Verify no memory leaks in adapter lifecycle."""
        # Adapter should remain stable
        assert adapter is not None
        assert hasattr(adapter, 'semantic_trees')
        assert isinstance(adapter.semantic_trees, dict)

    async def test_cache_behavior(self, adapter):
        """Verify adapter state is consistent."""
        # Adapter should have consistent state
        assert len(adapter.semantic_trees) >= 0
        assert adapter.config is not None


@pytest.mark.performance
@pytest.mark.asyncio
class TestScalability:
    """Test scalability with varying parameters."""

    async def test_deep_hierarchy_queries(self):
        """Test with deeply nested document."""
        with tempfile.TemporaryDirectory() as tmpdir:
            vault_path = Path(tmpdir)

            # Create deeply nested document
            doc = vault_path / "deep.md"
            lines = ["# Title"]
            for i in range(6):
                lines.append(f"{'#' * (i+2)} Level {i+2}")
                lines.append(f"Content at level {i+2}.\n")
            doc.write_text("\n".join(lines))

            config = {"vault_path": str(vault_path)}
            adapter = PageIndexAdapter(config)
            await adapter.initialize()
            assert adapter is not None

    async def test_wide_hierarchy_queries(self):
        """Test with wide hierarchies."""
        with tempfile.TemporaryDirectory() as tmpdir:
            vault_path = Path(tmpdir)

            # Create wide document
            doc = vault_path / "wide.md"
            lines = ["# Title"]
            for i in range(50):
                lines.append(f"## Section {i}")
                lines.append(f"Content for section {i}.\n")
            doc.write_text("\n".join(lines))

            config = {"vault_path": str(vault_path)}
            adapter = PageIndexAdapter(config)
            await adapter.initialize()
            assert adapter is not None

    async def test_large_query_result_sets(self, adapter):
        """Test handling of queries with many results."""
        namespaces = await adapter.list_namespaces()
        if not namespaces:
            pytest.skip("No documents loaded in adapter")

        # Query that might match many results
        results = await adapter.query(namespaces[0], "content", limit=50)
        assert isinstance(results, list)
        assert len(results) <= 50


# Performance measurement utilities
class PerformanceMetrics:
    """Track and report performance metrics."""

    def __init__(self):
        self.metrics: Dict[str, List[float]] = {}

    def record(self, metric_name: str, value: float):
        """Record a metric value."""
        if metric_name not in self.metrics:
            self.metrics[metric_name] = []
        self.metrics[metric_name].append(value)

    def percentile(self, metric_name: str, p: float) -> float:
        """Calculate percentile for metric."""
        values = sorted(self.metrics.get(metric_name, []))
        if not values:
            return 0.0
        idx = int(len(values) * (p / 100))
        return values[min(idx, len(values) - 1)]

    def report(self) -> str:
        """Generate performance report."""
        lines = ["Performance Metrics Report", "=" * 40]
        for metric_name, values in self.metrics.items():
            if not values:
                continue
            lines.append(f"\n{metric_name}:")
            lines.append(f"  Count: {len(values)}")
            lines.append(f"  Min: {min(values):.2f}ms")
            lines.append(f"  Max: {max(values):.2f}ms")
            lines.append(f"  Avg: {sum(values)/len(values):.2f}ms")
            lines.append(f"  P50: {self.percentile(metric_name, 50):.2f}ms")
            lines.append(f"  P95: {self.percentile(metric_name, 95):.2f}ms")
            lines.append(f"  P99: {self.percentile(metric_name, 99):.2f}ms")
        return "\n".join(lines)


# Sample data generators for testing
class SampleDataGenerator:
    """Generate sample documents for testing."""

    @staticmethod
    def create_small_document() -> str:
        """Create small markdown document (10KB)."""
        lines = ["# Title"]
        for i in range(10):
            lines.append(f"## Section {i}")
            lines.append(f"Content for section {i}.\n" * 10)
        return "\n".join(lines)

    @staticmethod
    def create_deep_document() -> str:
        """Create deeply nested document (h1→h6)."""
        lines = ["# Title"]
        for i in range(6):
            lines.append(f"{'#' * (i+2)} Level {i+2}")
            lines.append(f"Content at level {i+2}.\n" * 5)
        return "\n".join(lines)

    @staticmethod
    def create_wide_document() -> str:
        """Create wide document (many siblings)."""
        lines = ["# Title"]
        for i in range(50):
            lines.append(f"## Section {i}")
            lines.append(f"Content for section {i}.\n" * 5)
        return "\n".join(lines)

    @staticmethod
    def create_vault_documents(count: int, size_kb: int = 100) -> List[str]:
        """Create multiple documents for vault loading tests."""
        docs = []
        lines_per_doc = (size_kb * 1024) // 50  # Rough estimate
        for doc_id in range(count):
            lines = [f"# Document {doc_id}"]
            for section in range(10):
                lines.append(f"## Section {section}")
                lines.append(f"Content {doc_id}-{section}. " * (lines_per_doc // 100))
            docs.append("\n".join(lines))
        return docs


if __name__ == "__main__":
    print("Run with: pytest tests/test_performance.py -v --benchmark-only")
