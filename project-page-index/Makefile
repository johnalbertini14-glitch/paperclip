.PHONY: help install install-dev test test-cov test-verbose lint format clean

help:
	@echo "PageIndex Development Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make install          Install dependencies"
	@echo "  make install-dev      Install dependencies + dev tools"
	@echo ""
	@echo "Testing:"
	@echo "  make test             Run all tests"
	@echo "  make test-cov         Run tests with coverage report"
	@echo "  make test-verbose     Run tests with verbose output"
	@echo ""
	@echo "Code Quality:"
	@echo "  make lint             Run pylint on source code"
	@echo "  make format           Format code with black"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean            Remove cache and build artifacts"
	@echo "  make build            Build distribution package"

install:
	pip install -r requirements.txt

install-dev:
	pip install -r requirements.txt
	pip install pytest pytest-asyncio pytest-cov black mypy pylint

test:
	python -m pytest tests/

test-cov:
	python -m pytest tests/ --cov=src --cov-report=html --cov-report=term

test-verbose:
	python -m pytest tests/ -v -s

lint:
	pylint src/ --exit-zero

format:
	black --line-length=100 src/ tests/

clean:
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
	find . -type d -name "*.egg-info" -exec rm -rf {} +
	rm -rf .pytest_cache .coverage htmlcov build dist

build: clean
	python -m build
