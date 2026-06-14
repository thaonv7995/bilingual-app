#!/usr/bin/env python3
import sys
import argparse
from pathlib import Path

# Add backend directory to PYTHONPATH
backend_dir = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(backend_dir))

try:
    from api.database import SessionLocal, User
    from api.auth import get_password_hash
except ImportError as e:
    print(f"ImportError: Could not import backend modules. Make sure you run this script inside the virtual environment.")
    print(e)
    sys.exit(1)

def recreate_admin(username, password):
    db = SessionLocal()
    try:
        hashed_pw = get_password_hash(password)
        user = db.query(User).filter(User.username == username).first()
        if user:
            user.password_hash = hashed_pw
            user.is_admin = True
            db.commit()
            print(f"Success: Reset password for existing admin '{username}' to '{password}'.")
        else:
            new_user = User(username=username, password_hash=hashed_pw, is_admin=True)
            db.add(new_user)
            db.commit()
            print(f"Success: Created new admin user '{username}' with password '{password}'.")
    except Exception as e:
        db.rollback()
        print(f"Error: {e}")
        sys.exit(1)
    finally:
        db.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Create or recreate an Admin user in the Bilingual Library database.")
    parser.add_argument("--username", default="admin", help="Admin username (default: admin)")
    parser.add_argument("--password", default="admin123", help="Admin password (default: admin123)")
    args = parser.parse_args()
    
    recreate_admin(args.username, args.password)
