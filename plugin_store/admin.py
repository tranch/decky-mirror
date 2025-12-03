import os
import json
import hashlib
import string
import magic


from pathlib import Path
from datetime import datetime
from urllib.parse import urljoin
from fastapi import (Request, Header, UploadFile, File,
                     APIRouter, Depends, HTTPException, status)
from pydantic import BaseModel
from typing import List, Optional
from sqlalchemy.orm import Session

from models import Plugin, PluginVersion
from database import get_db
from config import ARTIFACT_DIR, ALLOWED_MIME_TYPES

ADMIN_TOKEN = os.getenv("PLUGIN_STORE_ADMIN_TOKEN")


def parse_iso8601(s: Optional[str]) -> Optional[datetime]:
    """Parse ISO8601 string like '2025-10-15T22:29:47Z' to datetime."""
    if not s:
        return None
    # Replace 'Z' with '+00:00' to make it ISO8601 compatible for fromisoformat
    if s.endswith("Z"):
        s = s.replace("Z", "+00:00")
    return datetime.fromisoformat(s)


class PluginDetail(BaseModel):
    id: int
    upstream_id: Optional[int]
    name: str
    visible: bool
    downloads: int
    updates: int

    class Config:
        from_attributes = True


class PluginCreate(BaseModel):
    name: str
    author: str
    tags: List[str]
    description: str
    image_url: Optional[str] = None


class PluginVisibilityUpdate(BaseModel):
    visible: bool


class PluginVersionCreate(BaseModel):
    name: str
    hash: str
    artifact: Optional[str] = None
    created: Optional[str] = None


class PluginVersionDetail(BaseModel):
    id: int
    name: str
    hash: str
    artifact: Optional[str] = None
    created: Optional[datetime] = None
    downloads: int
    updates: int

    class Config:
        from_attributes = True

class ArtifactUploadPayload(BaseModel):
    file: UploadFile = File(...)


class PluginArtifactDetail(BaseModel):
    plugin: str
    artifact: str
    hash: str

def verify_admin_token(
    token: str = Header(None, alias="X-Plugin-Store-Token"),
):
    """
    Very simple header-based token auth.

    Client must send:
      X-Plugin-Store-Token: <value of PLUGIN_STORE_ADMIN_TOKEN>
    """
    if not ADMIN_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Service not configured properly.",
        )

    if not token or token != ADMIN_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing admin token.",
        )


def slugify(value: str) -> str:
    """Very simple slug function for filesystem paths."""
    value = value.strip().lower().replace(" ", "-")
    allowed = string.ascii_lowercase + string.digits + "-_"
    slug = "".join(ch for ch in value if ch in allowed)
    return slug or "plugin"


def compute_sha256(f) -> str:
    """Compute sha256 hash for a file on disk."""
    h = hashlib.sha256()
    for chunk in iter(lambda: f.read(8192), b""):
        h.update(chunk)
    return h.hexdigest()


router = APIRouter(
    prefix="/internal",
    tags=["internal"],
    dependencies=[Depends(verify_admin_token)],
)


@router.post("/plugins")
async def admin_create_plugin(
    payload: PluginCreate,
    db: Session = Depends(get_db),
):
    """Create a new plugin."""
    plugin = Plugin(
        name=payload.name,
        author=payload.author,
        description=payload.description,
        tags=json.dumps(payload.tags),
        visible=False,
        downloads=0,
        updates=0,
        created=datetime.utcnow(),
        updated=datetime.utcnow(),
    )
    db.add(plugin)
    db.commit()
    db.refresh(plugin)

    return {
        "id": plugin.id,
        "name": plugin.name,
    }


@router.post("/plugins/{plugin_id}/versions")
async def admin_publish_plugin_version(
    plugin_id: int,
    payload: PluginVersionCreate,
    db: Session = Depends(get_db),
):
    """Publish a new version for a plugin."""
    plugin = db.query(Plugin).filter(Plugin.id == plugin_id).first()
    if plugin is None:
        raise HTTPException(status_code=404, detail="Plugin not found")

    # Check if a version with the same (plugin_id, name, hash) already exists
    existing_version = (
        db.query(PluginVersion)
        .filter(
            PluginVersion.plugin_id == plugin_id,
            PluginVersion.name == payload.name,
            PluginVersion.hash == payload.hash,
        )
        .first()
    )

    if existing_version:
        # Update existing version's metadata, but preserve downloads and updates
        if payload.artifact is not None:
            existing_version.artifact = payload.artifact
        if payload.created is not None:
            existing_version.created = parse_iso8601(payload.created)
        db.commit()
        db.refresh(existing_version)
        version = existing_version
    else:
        # Create new version
        version = PluginVersion(
            plugin_id=plugin.id,
            name=payload.name,
            hash=payload.hash,
            created=parse_iso8601(payload.created) if payload.created else datetime.utcnow(),
            downloads=0,
            updates=0,
            artifact=payload.artifact,
        )
        db.add(version)
        db.commit()
        db.refresh(version)

    return {
        "id": version.id,
        "name": version.name,
        "hash": version.hash,
        "created": version.created.isoformat().replace("+00:00", "Z") if version.created else None,
        "downloads": version.downloads,
        "updates": version.updates,
    }


@router.get("/plugins/{plugin_id}/versions", response_model=List[PluginVersionDetail])
async def admin_list_plugin_versions(
    plugin_id: int,
    db: Session = Depends(get_db),
):
    """List all versions for a plugin."""
    plugin = db.query(Plugin).filter(Plugin.id == plugin_id).first()

    if not plugin:
        raise HTTPException(status_code=404, detail="Plugin not found")

    versions = (
        db.query(PluginVersion)
        .filter(PluginVersion.plugin_id == plugin.id)
        .order_by(PluginVersion.id.asc())
        .all()
    )

    return versions


@router.patch("/plugins/{plugin_id}/visibility")
async def admin_update_plugin_visibility(
    plugin_id: int,
    payload: PluginVisibilityUpdate,
    db: Session = Depends(get_db),
):
    """Update the visibility of a plugin."""
    plugin = db.query(Plugin).filter(Plugin.id == plugin_id).first()
    if plugin is None:
        raise HTTPException(status_code=404, detail="Plugin not found")

    plugin.visible = payload.visible
    db.commit()
    db.refresh(plugin)

    return {
        "id": plugin.id,
        "name": plugin.name,
        "visible": plugin.visible,
    }


@router.get("/plugins", response_model=List[PluginDetail])
async def admin_list_plugins(
    db: Session = Depends(get_db),
):
    """List all plugins."""
    plugins = db.query(Plugin).order_by(Plugin.id.asc()).all()
    return plugins


@router.post("/plugins/{plugin_id}/artifacts",
             response_model=PluginArtifactDetail,
             status_code=status.HTTP_201_CREATED)
async def upload_plugin_artifact(
    plugin_id: int,
    file: UploadFile = File(...),
    request: Request = None,
    db: Session = Depends(get_db)
):
    """
    Upload an artifact file for a given plugin.

    Before create a new plugin version, the artifact must be uploaded
    using this endpoint. The uploaded file is validated, stored, and its
    SHA256 hash is computed. The response includes the URL to access the
    stored artifact and its hash, which can then be used when creating
    a new plugin version.
    """
    CHUNK_SIZE = 8192

    plugin = db.query(Plugin).filter(Plugin.id == plugin_id).first()
    if plugin is None:
        raise HTTPException(status_code=404, detail="Plugin not found")

    plugin_slug = slugify(plugin.name)

    first_chunk = await file.read(CHUNK_SIZE)
    if not first_chunk:
        raise HTTPException(status_code=400, detail="Empty file is not allowed.")

    mime_type = magic.from_buffer(first_chunk, mime=True)
    suffix = ALLOWED_MIME_TYPES.get(mime_type)
    if not suffix:
        raise HTTPException(status_code=400, detail="Invalid file type.")

    target_dir = Path(ARTIFACT_DIR).resolve() / plugin_slug
    target_dir.mkdir(parents=True, exist_ok=True)

    hasher = hashlib.sha256()

    target_path = None
    temp_path = target_dir / f"{plugin_slug}.upload"

    with temp_path.open("wb") as out:
        hasher.update(first_chunk)
        out.write(first_chunk)

        while True:
            chunk = await file.read(CHUNK_SIZE)
            if not chunk:
                break
            hasher.update(chunk)
            out.write(chunk)

    sha256 = hasher.hexdigest()
    final_name = f"{sha256}{suffix}"
    target_path = target_dir / final_name

    # rename temp file to final name
    temp_path.replace(target_path)

    relative_path = f"{plugin_slug}/{target_path.name}"
    artifact_url = request.url_for("artifact_files", path=relative_path)

    return {
        "plugin": plugin.name,
        "artifact": str(artifact_url),
        "hash": sha256,
    }

