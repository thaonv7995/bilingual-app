# Bilingual Book Reader Backend & CLI

The core python sidecar for the Bilingual Book Reader ecosystem. This directory contains the FastAPI web service, the AI book translation/alignment agent, and the `books-cli` utility.

---

## 📂 Project Structure

```text
application/backend/
├── api/                    # FastAPI Server Application
│   ├── routes/             # Modularized HTTP Router Endpoints
│   │   ├── auth.py         # Login, Registration, JWT sessions
│   │   ├── books.py        # Library queries, upload, download, progress, highlights
│   │   ├── admin.py        # API Keys & User permissions
│   │   └── chat.py         # AI assistant completions streaming proxy
│   ├── config.py           # Paths and credentials configurations
│   ├── database.py         # SQLAlchemy schemas and DB connection helpers
│   └── main.py             # FastAPI App definition and entrypoint shebang
├── books_agent/            # AI agent translation and alignment logic
├── books_cli/              # Command line interface scripts
├── books_core/             # Core layout, PDF parsing, packing, and validation modules
├── docs/                   # Documentation and coding standards
│   ├── CONVENTIONS.md      # Python code conventions
│   └── FEATURES.md         # Detailed features guide
├── scripts/                # Python processing scripts (HTML layout, overflow fixing)
├── tests/                  # Automated unit test suites
├── pyproject.toml          # Editable package configuration
└── requirements-api.txt    # HTTP backend server dependencies
```

---

## 🚀 Quickstart Guide

### 1. Rebuild Virtual Environment
A local virtual environment `.venv/` must be initialized under the parent `/application/` directory.

```bash
cd application
rm -rf .venv  # Clean up existing venv if broken
python3 -m venv .venv
source .venv/bin/activate
```

### 2. Install Dependencies
Install the CLI tool as an editable package, then install the API server requirements:

```bash
# Repair python paths and install books-core CLI
bash scripts/fix-venv.sh

# Install API requirements
.venv/bin/python3 -m pip install -r backend/requirements-api.txt
```

### 3. Run the Server
From the project **root** directory, execute the launcher script:

```bash
python3 server.py
```
The FastAPI backend server will start on port `27099` (e.g. serving the database, secure books path `/books/*`, and UI static assets).

---

## 🛠️ CLI Commands (books-cli)

Once installed, use `books-cli` to ingest and align books:

```bash
# Check CLI installation
books-cli --help

# Ingest a raw PDF book
books-cli ingest --pdf path/to/book.pdf

# Render page 1 translation using LLM
books-cli render --book books/my-book --page 1 --provider cursor --page-pdf
```

---

## 🧪 Running Tests

Ensure your code compiles and routes are functional:

```bash
cd application/backend
../.venv/bin/pytest
```

---

## 📖 Additional Documentation

For deeper details, consult the following documents:
- **Coding Conventions**: [CONVENTIONS.md](file:///Users/thaonv/Projects/Personal/bilingual-app/application/backend/docs/CONVENTIONS.md)
- **Detailed Feature Guide**: [FEATURES.md](file:///Users/thaonv/Projects/Personal/bilingual-app/application/backend/docs/FEATURES.md)
