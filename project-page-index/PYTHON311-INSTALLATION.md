# Python 3.11 Installation & Troubleshooting

**Status**: Required for Phase 4 test execution  
**Current VPS Status**: NOT INSTALLED  
**Blocker**: REVA-384, REVA-516 Phase 4

---

## Problem Statement

PageIndex adapter tests require Python 3.11 runtime. The VPS currently has:
- No system Python 3.11
- No `/opt/python` or alternative installation
- No Docker or containerization available
- REVA-358 (repo migration) marked complete but runtime still missing

**Impact**: Cannot execute pytest suite for Phase 4 validation

---

## Installation Options

### Option 1: System Package Manager (apt) — Preferred

**Requirements**: Root access, apt package cache

```bash
# Update package cache
sudo apt update

# Install Python 3.11 and development headers
sudo apt install -y python3.11 python3.11-venv python3.11-dev

# Verify installation
python3.11 --version
python3.11 -m venv --help

# Expected output: Python 3.11.x
```

**Success Indicators**:
```bash
which python3.11
# Output: /usr/bin/python3.11

python3.11 -c "import sys; print(sys.version)"
# Output: Python 3.11.x (default, ...)
```

**Troubleshooting**:
- If `apt install` fails: Package might be named `python3.11` but in universe repo
  - Solution: `sudo add-apt-repository universe && sudo apt update`
- If venv fails: Install `python3.11-venv`
  - Solution: `sudo apt install python3.11-venv`

---

### Option 2: pyenv (User-level Installation)

**Requirements**: No root access needed

```bash
# Install pyenv (if not already installed)
git clone https://github.com/pyenv/pyenv.git ~/.pyenv
export PATH="$HOME/.pyenv/bin:$PATH"
eval "$(~/.pyenv/init -)"

# Add to ~/.bashrc for persistence
echo 'export PATH="$HOME/.pyenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(pyenv init -)"' >> ~/.bashrc

# Install Python 3.11
pyenv install 3.11.8

# Set as local version (in project directory)
cd /paperclip/instances/default/workspaces/e5efa3c2-9c67-4617-8612-998ea68edfed/
pyenv local 3.11.8

# Verify
python --version
# Output: Python 3.11.8
```

**Advantages**:
- No root required
- Easy to manage multiple Python versions
- Project-specific version selection

**Disadvantages**:
- Slower than system package
- Compiles from source
- Requires build tools (gcc, make, etc.)

---

### Option 3: Direct Binary Download

**Requirements**: Compatible Linux binary available

```bash
# Create Python installation directory
mkdir -p /opt/python

# Download Python 3.11 binary (example)
wget https://www.python.org/ftp/python/3.11.8/Python-3.11.8.tar.xz
tar xf Python-3.11.8.tar.xz
cd Python-3.11.8

# Configure and compile
./configure --prefix=/opt/python/3.11 --enable-optimizations
make -j$(nproc)
make install

# Create symlink
ln -s /opt/python/3.11/bin/python3.11 /usr/local/bin/python3.11

# Verify
python3.11 --version
```

**Advantages**:
- Full control over compilation
- Can optimize for specific hardware

**Disadvantages**:
- Long compilation time (30+ minutes)
- Requires build tools (gcc, make, OpenSSL dev, etc.)
- Large disk space needed

---

### Option 4: Docker Container (If Docker Available)

**Requirements**: Docker installation and access

```dockerfile
FROM python:3.11-slim

WORKDIR /paperclip/instances/default/workspaces/e5efa3c2-9c67-4617-8612-998ea68edfed/project-page-index/

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["pytest", "tests/", "-v"]
```

**Build and Run**:
```bash
docker build -t pageindex-tests:3.11 .
docker run --rm pageindex-tests:3.11
```

**Status**: Docker not currently available on VPS

---

### Option 5: Cloud Python Runtime Service

**Requirements**: Cloud account (AWS Lambda, GCP Functions, etc.)

Use managed Python runtime:

```bash
# AWS SAM example
sam init --runtime python3.11
sam build
sam local start-api
```

**Advantages**:
- No local installation needed
- Scalable
- Managed infrastructure

**Disadvantages**:
- Requires cloud account
- Network latency
- Cost implications

---

## Recommended Installation Path

### For VPS (Current Environment)

**Try in this order**:

1. **Try apt** (fastest if available):
   ```bash
   sudo apt update && sudo apt install -y python3.11 python3.11-venv
   ```

2. **If apt fails, try pyenv** (user-level):
   ```bash
   git clone https://github.com/pyenv/pyenv.git ~/.pyenv
   export PATH="$HOME/.pyenv/bin:$PATH"
   pyenv install 3.11.8
   ```

3. **If both fail, compile from source**:
   - Takes 30-60 minutes
   - Requires build tools
   - Full control over optimization

---

## Verification After Installation

### Test 1: Python CLI

```bash
python3.11 --version
# Expected: Python 3.11.x

python3.11 -c "import sys; print(sys.version_info)"
# Expected: sys.version_info(major=3, minor=11, ...)
```

### Test 2: Virtual Environment

```bash
python3.11 -m venv test_venv
source test_venv/bin/activate
python -m pip install --upgrade pip
python -c "import sys; print(sys.prefix)"
# Expected: Venv path
```

### Test 3: Package Installation

```bash
cd /paperclip/instances/default/workspaces/e5efa3c2-9c67-4617-8612-998ea68edfed/project-page-index/

# Create venv
python3.11 -m venv .venv311
source .venv311/bin/activate

# Install requirements
pip install -r requirements.txt

# Test import
python -c "import pytest; print(pytest.__version__)"
```

### Test 4: Run Phase 4 Tests

```bash
pytest tests/ -v --tb=short
# Expected: Test results with X passed/failed
```

---

## Troubleshooting

### "python3.11: command not found"

**Check what Python versions are available**:
```bash
ls /usr/bin/python* 
# Look for python3.11, python3.10, python3.9, etc.

which python3
# Check current Python location

python3 --version
# Check current Python version
```

**Solutions**:
1. Install via apt: `sudo apt install python3.11`
2. Use pyenv: `pyenv install 3.11.8`
3. Use available version if 3.11 not required:
   - Check requirements.txt for version requirements
   - `.python-version` file specifies 3.11 (could be modified to 3.10)

### "ModuleNotFoundError: No module named 'venv'"

**Cause**: Python venv module not installed

**Solution**:
```bash
sudo apt install python3.11-venv

# Or check if using system Python
which python3.11
python3.11 -m venv --help
```

### "pip install" fails with SSL errors

**Cause**: Missing OpenSSL development libraries

**Solution**:
```bash
sudo apt install -y libssl-dev libffi-dev python3.11-dev

# Reinstall Python with SSL support
python3.11 -m pip install --upgrade pip --no-cache-dir
```

### Virtual environment creation fails

**Cause**: Missing venv or setuptools

**Solution**:
```bash
python3.11 -m ensurepip --upgrade
python3.11 -m pip install --upgrade setuptools wheel
python3.11 -m venv /path/to/venv
```

### Tests hang or timeout

**Possible Causes**:
1. Slow disk I/O
2. System resource constraints
3. Test fixture issues

**Debugging**:
```bash
# Run single test with verbose output
pytest tests/test_adapter.py::TestPageIndexIntegration::test_adapter_initialization_with_real_vault -vv -s

# Run with timeout
pytest tests/ -v --timeout=60

# Profile execution
python -m cProfile -s cumtime -m pytest tests/test_integration.py
```

---

## Build Tools Requirement

If compiling Python from source, install build dependencies:

```bash
# Ubuntu/Debian
sudo apt install -y build-essential libssl-dev libffi-dev \
  libreadline-dev libbz2-dev libsqlite3-dev zlib1g-dev

# CentOS/RHEL
sudo yum install -y gcc openssl-devel libffi-devel \
  readline-devel bzip2-devel sqlite-devel zlib-devel

# Alpine
apk add --no-cache gcc musl-dev openssl-dev libffi-dev \
  readline-dev bzip2-dev sqlite-dev zlib-dev
```

---

## Verification Checklist

Before attempting Phase 4 tests:

- [ ] Python 3.11 installed: `python3.11 --version`
- [ ] venv module available: `python3.11 -m venv --help`
- [ ] Virtual environment created: `.venv311/bin/activate` exists
- [ ] pip upgraded: `pip --version` shows recent version
- [ ] Dependencies installed: `pip list` includes pytest, pytest-asyncio
- [ ] Tests discovered: `pytest --collect-only` shows 37+ tests
- [ ] Imports work: `python -c "from src.adapter import PageIndexAdapter"`

---

## Timeline Estimate

| Method | Time | Difficulty |
|--------|------|-----------|
| apt install | 2-5 min | Easy |
| pyenv | 15-30 min | Medium |
| Compile source | 30-60 min | Hard |
| Docker setup | 10-15 min | Medium (if Docker available) |

---

## Success Indicators

After installation, confirm:

```bash
python3.11 --version
# Python 3.11.8 (or similar)

python3.11 -m pip list | grep pytest
# pytest-X.X.X
# pytest-asyncio-X.X.X

cd /paperclip/instances/default/workspaces/e5efa3c2-9c67-4617-8612-998ea68edfed/project-page-index/
pytest tests/ --collect-only | tail -1
# X tests selected
```

---

## Next Action

When Python 3.11 is available:
1. Install with preferred method above
2. Verify with checklist
3. Execute: `pytest tests/ -v`
4. Proceed with PHASE4-EXECUTION-GUIDE.md

---

**Owner**: Code Worker B  
**Created**: 2026-04-25  
**Status**: Documentation for unblocking Python 3.11 blocker
