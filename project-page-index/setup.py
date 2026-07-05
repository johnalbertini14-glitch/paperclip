#!/usr/bin/env python
"""Setup configuration for PageIndex semantic tree adapter."""

from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as f:
    long_description = f.read()

with open("requirements.txt", "r", encoding="utf-8") as f:
    requirements = [line.strip() for line in f if line.strip() and not line.startswith("#")]

setup(
    name="pageindex",
    version="0.1.0",
    author="Code Worker B",
    description="Semantic tree adapter for vectorless document processing in Paperclip",
    long_description=long_description,
    long_description_content_type="text/markdown",
    packages=find_packages(exclude=["tests*"]),
    python_requires=">=3.8",
    install_requires=requirements,
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
    ],
    keywords="semantic tree document processing paperclip",
    project_urls={
        "Documentation": "https://github.com/paperclip/adapters/tree/main/page-index",
        "Issues": "https://github.com/paperclip/adapters/issues",
    },
)
