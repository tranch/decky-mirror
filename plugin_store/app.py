import os
import json
import requests

from pathlib import Path
from fastapi import FastAPI, Depends, Query, status
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from sqlalchemy import or_
from typing import List, Optional
from datetime import datetime

from models import Plugin, PluginVersion
from database import init_db, get_db
from admin import internal_router


ADMIN_TOKEN = os.getenv("PLUGIN_STORE_ADMIN_TOKEN", "")
app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(internal_router)


@app.on_event("startup")
def on_startup():
    """Initialize the database on startup."""
    init_db()


def load_plugins_from_source() -> List[dict]:
    """Load plugins list from local JSON file, or fetch from upstream if missing."""
    download_path = Path("/srv/plugins")
    download_path.mkdir(parents=True, exist_ok=True)

    target_file = download_path / "plugins.json"

    if not target_file.exists():
        # First time: fetch from upstream
        resp = requests.get("https://plugins.deckbrew.xyz/plugins", timeout=15)
        resp.raise_for_status()
        target_file.write_text(resp.text, encoding="utf-8")

    with target_file.open("r", encoding="utf-8") as f:
        plugins = json.load(f)

    return plugins


def ensure_plugins_synced(db: Session) -> None:
    """
    Sync plugins from upstream JSON into the local DB.

    - If a Plugin (by upstream_id) does not exist: create it with visible=False.
    - If it exists: update basic metadata, but DO NOT touch `visible`.
    - For Versions:
        - If (name, hash) 不存在：新增，並填入 artifact（若有）。
        - 如果存在：更新下載/更新數、created、artifact（若有提供）。
    """
    plugins_data = load_plugins_from_source()

    for plugin_item in plugins_data:
        upstream_id = plugin_item.get("id")
        if upstream_id is None:
            continue

        plugin: Plugin | None = (
            db.query(Plugin)
            .filter(Plugin.upstream_id == upstream_id)
            .first()
        )

        if plugin is None:
            plugin = Plugin(
                upstream_id=upstream_id,
                name=plugin_item.get("name"),
                author=plugin_item.get("author"),
                description=plugin_item.get("description"),
                tags=json.dumps(plugin_item.get("tags", [])),
                visible=False,
                image_url=plugin_item.get("image_url"),
                downloads=plugin_item.get("downloads", 0),
                updates=plugin_item.get("updates", 0),
                created=parse_iso8601(plugin_item.get("created")),
                updated=parse_iso8601(plugin_item.get("updated")),
            )
            db.add(plugin)
            db.flush()
        else:
            plugin.name = plugin_item.get("name", plugin.name)
            plugin.author = plugin_item.get("author", plugin.author)
            plugin.description = plugin_item.get("description", plugin.description)
            plugin.tags = json.dumps(plugin_item.get("tags", json.loads(plugin.tags or "[]")))
            plugin.image_url = plugin_item.get("image_url", plugin.image_url)
            plugin.downloads = plugin_item.get("downloads", plugin.downloads)
            plugin.updates = plugin_item.get("updates", plugin.updates)
            created = parse_iso8601(plugin_item.get("created"))
            updated = parse_iso8601(plugin_item.get("updated"))
            if created:
                plugin.created = created
            if updated:
                plugin.updated = updated

        existing_versions: dict[tuple[str, str], PluginVersion] = {
            (v.name, v.hash): v for v in plugin.versions
        }

        for version_item in plugin_item.get("versions", []):
            v_name = version_item.get("name")
            v_hash = version_item.get("hash")
            key = (v_name, v_hash)

            artifact = version_item.get("artifact")

            if key not in existing_versions:
                version = PluginVersion(
                    plugin_id=plugin.id,
                    name=v_name,
                    hash=v_hash,
                    created=parse_iso8601(version_item.get("created")),
                    downloads=version_item.get("downloads", 0),
                    updates=version_item.get("updates", 0),
                    artifact=artifact,
                )
                db.add(version)
            else:
                version = existing_versions[key]
                created = parse_iso8601(version_item.get("created"))

                if created:
                    version.created = created

                version.downloads = version_item.get("downloads", version.downloads)
                version.updates = version_item.get("updates", version.updates)

                if artifact is not None:
                    version.artifact = artifact

    db.commit()


def plugin_to_dict(plugin: Plugin) -> dict:
    """Convert Plugin ORM object to dict compatible with Decky Loader."""
    return {
        "id": plugin.upstream_id or plugin.id,  # fallback to local id if no upstream id
        "name": plugin.name,
        "author": plugin.author,
        "description": plugin.description,
        "tags": json.loads(plugin.tags) if plugin.tags else [],
        "versions": [
            {
                "name": v.name,
                "hash": v.hash,
                "created": v.created.isoformat().replace("+00:00", "Z") if v.created else None,
                "downloads": v.downloads,
                "updates": v.updates,
            }
            for v in plugin.versions
        ],
        "visible": plugin.visible,
        "image_url": plugin.image_url,
        "downloads": plugin.downloads,
        "updates": plugin.updates,
        "created": plugin.created.isoformat().replace("+00:00", "Z") if plugin.created else None,
        "updated": plugin.updated.isoformat().replace("+00:00", "Z") if plugin.updated else None,
    }


def parse_iso8601(s: Optional[str]) -> Optional[datetime]:
    """Parse ISO8601 string like '2025-10-15T22:29:47Z' to datetime."""
    if not s:
        return None
    # Replace 'Z' with '+00:00' to make it ISO8601 compatible for fromisoformat
    if s.endswith("Z"):
        s = s.replace("Z", "+00:00")
    return datetime.fromisoformat(s)


@app.get("/")
async def index():
    return HTMLResponse("""<!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <link href="data:image/x-icon;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQEAYAAABPYyMiAAAABmJLR0T///////8JWPfcAAAACXBIWXMAAABIAAAASABGyWs+AAAAF0lEQVRIx2NgGAWjYBSMglEwCkbBSAcACBAAAeaR9cIAAAAASUVORK5CYII=" rel="icon" type="image/x-icon" />
        <title>Plugin List</title>
    </head>
    <body>
        <h1>Available Plugins</h1>
        <form id="search-form">
            <input type="text" id="search-query" placeholder="Search plugins...">
            <button type="submit">Search</button>
        </form>
        <ul id="plugin-list"></ul>
        <script>
            async function fetchPlugins(keyword = '') {
                const apiUrl = new URL(window.location.origin + '/plugins');
                if (keyword) {
                    apiUrl.searchParams.append('query', keyword);
                }
                const response = await fetch(apiUrl);
                const plugins = await response.json();
                const list = document.getElementById('plugin-list');
                plugins.forEach(plugin => {
                    const listItem = document.createElement('li');
                    itemTitle = document.createElement('h3');
                    itemTitle.textContent = plugin.name;
                    itemImage = document.createElement('img');
                    itemImage.src = plugin.image_url;
                    itemImage.alt = plugin.name;
                    itemImage.width = 256;
                    itemDescription = document.createElement('p');
                    itemDescription.textContent = plugin.description;
                    listItem.appendChild(itemTitle);
                    listItem.appendChild(itemImage);
                    listItem.appendChild(itemDescription);
                    list.appendChild(listItem);
                });
            }
            fetchPlugins();
            document.getElementById('search-form').addEventListener('submit', function(event) {
                event.preventDefault();
                const query = event.target.elements['search-query'].value;
                document.getElementById('plugin-list').innerHTML = '';
                fetchPlugins(query);
            });
        </script>
    </body>
    </html>""")


@app.get("/plugins")
async def get_plugins(query: Optional[str] = None,
                      db: Session = Depends(get_db)) -> List[dict]:
    """Endpoint to get the list of plugins, backed by SQLite."""
    ensure_plugins_synced(db)

    q = db.query(Plugin).filter(Plugin.visible)

    if query:
        like_pattern = f"%{query}%"
        q = q.filter(
            or_(
                Plugin.name.ilike(like_pattern),
                Plugin.description.ilike(like_pattern),
            )
        )

    plugins = q.all()
    return [plugin_to_dict(p) for p in plugins]


@app.post("/plugins/{plugin_name}/versions/{version_name}/increment")
async def increment_plugin_version_counter(
    plugin_name: str,
    version_name: str,
    isUpdate: bool = Query(..., description="True if this is an update, False if download"),
    db: Session = Depends(get_db),
):
    """
    Increment downloads/updates counters for a given plugin version.

    - plugin_name: the plugin's name as used by Decky (URL-decoded by FastAPI)
    - version_name: the version string, e.g. "1.2.0"
    - isUpdate:
        - True  -> increment `updates`
        - False -> increment `downloads`
    """    
    plugin = db.query(Plugin).filter(Plugin.name == plugin_name).first()

    if not plugin:
        return {"error": "Plugin not found"}

    version = (
        db.query(PluginVersion)
        .filter(
            PluginVersion.plugin_id == plugin.id,
            PluginVersion.name == version_name,
        )
        .first()
    )

    if not version:
        return {"error": "Plugin version not found"}, status.HTTP_404_NOT_FOUND

    if isUpdate:
        version.updates += 1
        plugin.updates += 1
    else:
        version.downloads += 1
        plugin.downloads += 1

    db.commit()

    return {}

