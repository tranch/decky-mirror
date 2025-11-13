import os
import json

from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Header, status
from sqlalchemy.orm import Session
from models import Plugin, PluginVersion
from database import get_db
from pydantic import BaseModel
from typing import List, Optional

ADMIN_TOKEN = os.getenv("PLUGIN_STORE_ADMIN_TOKEN")

class PluginAdminOut(BaseModel):
    id: int
    upstream_id: Optional[int]
    name: str
    visible: bool
    downloads: int
    updates: int

    class Config:
        orm_mode = True


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


internal_router = APIRouter(
    prefix="/internal",
    tags=["internal"],
    dependencies=[Depends(verify_admin_token)],
)

# create a plugin
@internal_router.post("/plugins")
async def admin_create_plugin(
    payload: PluginCreate,
    db: Session = Depends(get_db),
):
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
    }, status.HTTP_201_CREATED

# publish new version
@internal_router.post("/plugins/{plugin_id}/versions")
async def admin_publish_plugin_version(
    plugin_id: int,
    payload: PluginVersionCreate,
    db: Session = Depends(get_db),
):
    plugin = db.query(Plugin).filter(Plugin.id == plugin_id).first()
    if plugin is None:
        raise HTTPException(status_code=404, detail="Plugin not found")

    version = PluginVersion(
        plugin_id=plugin.id,
        name=payload.name,
        hash=payload.hash,
        created=datetime.utcnow(),
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
        "created": version.created.isoformat().replace("+00:00", "Z"),
        "downloads": version.downloads,
        "updates": version.updates,
    }, status.HTTP_201_CREATED

@internal_router.patch("/plugins/{plugin_id}/visibility")
async def admin_update_plugin_visibility(
    plugin_id: int,
    payload: PluginVisibilityUpdate,
    db: Session = Depends(get_db),
):
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


@internal_router.get("/plugins", response_model=List[PluginAdminOut])
async def admin_list_plugins(
    db: Session = Depends(get_db),
):
    plugins = db.query(Plugin).order_by(Plugin.id.asc()).all()
    return plugins

