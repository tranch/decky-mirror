from os import environ
from pathlib import Path

SQLALCHEMY_DB_PATH = environ.get("PLUGIN_STORE_DB_PATH", "./plugins.db")
SQLALCHEMY_DATABASE_URL = f"sqlite:////{Path(SQLALCHEMY_DB_PATH).resolve()}"

ARTIFACT_DIR = environ.get("PLUGIN_STORE_ARTIFACT_DIR", "./artifacts")

ALLOWED_MIME_TYPES = {"application/zip": ".zip"}

PLUGIN_DOWNLOAD_PATH = environ.get("PLUGIN_STORE_DOWNLOAD_PATH", "/plugins/download/")

