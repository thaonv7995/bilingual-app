"""Make the backend package root importable during tests.

The `api` package is path-based (see repo-root `server.py`, which prepends this
directory to sys.path at runtime), not installed via `pip install -e`. When
pytest is invoked as the `pytest` console script (as CI does) the cwd is NOT
added to sys.path, so `import api...` fails. This rootdir conftest is loaded
before test collection and fixes that for any invocation.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
