# Backend Coding Conventions

Guidelines and patterns for maintaining a standardized, clean, and robust codebase in the Python backend.

## 1. Code Style & Format

- **Compliance**: Follow [PEP 8](https://peps.python.org/pep-0008/) naming conventions.
  - Variable and function names: `snake_case` (e.g., `list_books`, `user_id`).
  - Class names: `PascalCase` (e.g., `ReadingProgress`, `UserPermission`).
  - Constants: `UPPER_SNAKE_CASE` (e.g., `SECRET_KEY`, `ALGORITHM`).
- **Indentation**: Standard 4-space indentation.
- **Imports**: Group imports in the following order, separated by a blank line:
  1. Standard library imports (e.g., `os`, `time`, `shutil`).
  2. Third-party library imports (e.g., `fastapi`, `sqlalchemy`, `jwt`).
  3. Local imports (e.g., `api.database`, `api.config`).

## 2. Type Hints

Always specify type hints for function parameters and return values. This ensures IDE autocomplete accuracy, facilitates automatic schema verification, and acts as self-documentation.

*Example:*
```python
from sqlalchemy.orm import Session
from api.database import User

def register_user(username: str, password_hash: str, db: Session) -> User:
    ...
```

## 3. Route Architecture & FastAPI APIRouter

- **Modularization**: Never place all endpoints in a single `main.py` file. Group routes into cohesive resources inside the `api/routes/` directory.
- **Prefixes & Tags**: Use explicit prefixes and tags in routers for clear separation of concerns in OpenAPI/Swagger documentation.
- **Include Routers**: Mount all modular routers in `api/main.py`.

*Example:*
```python
# In api/routes/auth.py
from fastapi import APIRouter

router = APIRouter(prefix="/api/auth", tags=["authentication"])

@router.post("/register")
def register(...):
    ...
```

## 4. Dependency Injection

- **Database Session**: Inject SQLAlchemy database session dynamically using `get_db`.
- **Authentication**: Rely on `get_current_user_or_apikey` or `require_admin` dependency injections for access control. Never manually parse JWTs or API headers inside the route function body.

*Example:*
```python
@router.get("/users")
def admin_list_users(
    admin: User = Depends(require_admin), 
    db: Session = Depends(get_db)
):
    ...
```

## 5. Error Handling

- Use FastAPI's standard `HTTPException` to return error responses to clients.
- Provide descriptive error details and use appropriate HTTP status codes:
  - `400 Bad Request` for invalid input parameters or client validation.
  - `401 Unauthorized` for missing or invalid authorization tokens.
  - `403 Forbidden` for operations not allowed under current user permissions.
  - `404 Not Found` for missing resources.
  - `500 Internal Server Error` for unexpected exceptions (catch errors and raise details carefully).

## 6. Configuration & Path Management

- Centralize all configurations, environment variables, and filesystem directory paths in [api/config.py](file:///Users/thaonv/Projects/Personal/bilingual-app/application/backend/api/config.py).
- Never hardcode dynamic path depths (e.g., `Path(__file__).parents[4]`) in specific router files; import paths like `WORKSPACE_ROOT` or `BOOKS_DIR` directly from `api.config`.
