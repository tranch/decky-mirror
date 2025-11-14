import os
import logging
from pathlib import Path
from typing import List, Dict, Any
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse

app = FastAPI(title="Mini GH Releases Mirror (filesystem)")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("uvicorn.error")

RELEASES_ROOT = Path(os.getenv("RELEASES_ROOT", "/srv/releases")).resolve()
RELEASE_BASE = os.getenv("RELEASE_BASE", "https://decky.mirror.example.com")


def repo_root(owner: str, repo: str) -> Path:
    """return /srv/releases/<owner>/<repo>"""
    return RELEASES_ROOT / owner / repo


def releases_dir(owner: str, repo: str) -> Path:
    """return /srv/releases/<owner>/<repo>/releases"""
    return repo_root(owner, repo) / "releases"


def downloads_dir(owner: str, repo: str) -> Path:
    """return /srv/releases/<owner>/<repo>/releases/download"""
    return releases_dir(owner, repo) / "download"


def latest_download_dir(owner: str, repo: str) -> Path:
    """return /srv/releases/<owner>/<repo>/releases/latest/download"""
    return releases_dir(owner, repo) / "latest" / "download"


def ensure_repo_exists(owner: str, repo: str) -> None:
    root = repo_root(owner, repo)
    if not root.exists():
        logger.warning("Repo not found on disk: %s/%s, %s", owner, repo, root)
        raise HTTPException(status_code=404, detail="repo not found")


def list_tags(owner: str, repo: str) -> List[str]:
    """
    /srv/releases/<owner>/<repo>/releases/download/<tag>/*
    """
    ddir = downloads_dir(owner, repo)
    if not ddir.exists():
        return []

    tags: List[str] = []
    for p in ddir.iterdir():
        if p.is_dir():
            tags.append(p.name)

    # sort by mtime desc
    tags.sort(key=lambda t: (ddir / t).stat().st_mtime, reverse=True)
    return tags


def resolve_latest_tag(owner: str, repo: str) -> str:
    """
    Resolve the latest tag for the given repo.
    """
    latest_dl = latest_download_dir(owner, repo)
    if latest_dl.exists():
        try:
            target = latest_dl.resolve()
            tag = target.name
            return tag
        except OSError as e:
            logger.error("Failed to resolve latest symlink: %s", e)
            pass

    tags = list_tags(owner, repo)
    if not tags:
        raise HTTPException(status_code=404, detail="no releases found")
    return tags[0]


def build_asset_entry(owner: str, repo: str, tag: str, file_path: Path) -> Dict[str, Any]:
    rel_url = f"{owner}/{repo}/releases/download/{tag}/{file_path.name}"
    if tag == "latest":
        rel_url = rel_url.replace(f"download/{tag}", "{tag}/download")
    return {
        "name": file_path.name,
        "size": file_path.stat().st_size,
        "created_at": _ts_to_iso(file_path.stat().st_ctime),
        "updated_at": _ts_to_iso(file_path.stat().st_mtime),
        "browser_download_url": f"{RELEASE_BASE}/{rel_url}",
        "content_type": "application/octet-stream",
        "browser_download_url": f"{RELEASE_BASE}/{rel_url}",
    }


def make_release(owner: str, repo: str, tag: str) -> Dict[str, Any]:
    ddir = downloads_dir(owner, repo) / tag

    if not ddir.exists() or not ddir.is_dir():
        logger.warning("Release not found on disk: %s/%s tag=%s, %s",
                       owner, repo, tag, ddir)
        raise HTTPException(status_code=404, detail="release not found")

    assets: List[Dict[str, Any]] = []

    for item in sorted(ddir.iterdir()):
        if item.is_file():
            assets.append(build_asset_entry(owner, repo, tag, item))

    return {
        "id": tag,
        "tag_name": tag,
        "name": tag,
        "prerelease": False,
        "assets": assets
    }


def make_releases(owner: str, repo: str, tags: List[str]) -> List[Dict[str, Any]]:
    return [make_release(owner, repo, tag) for tag in tags]

def _ts_to_iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


@app.get("/repos/{owner}/{repo}/releases/latest")
def get_latest_release(owner: str, repo: str):
    ensure_repo_exists(owner, repo)
    tag = resolve_latest_tag(owner, repo)
    return JSONResponse(make_release(owner, repo, tag))


@app.get("/repos/{owner}/{repo}/releases/{tag}")
def get_release(owner: str, repo: str, tag: str):
    """
    Examples:
    - /repos/o/r/releases/latest
    - /repos/o/r/releases/v1.2.3
    """
    ensure_repo_exists(owner, repo)

    if tag == "latest":
        tag = resolve_latest_tag(owner, repo)

    return JSONResponse(make_release(owner, repo, tag))


@app.get("/repos/{owner}/{repo}/releases")
def list_releases(owner: str, repo: str):
    ensure_repo_exists(owner, repo)
    tags = list_tags(owner, repo)
    if not tags:
        raise HTTPException(status_code=404, detail="no releases found")
    return JSONResponse(make_releases(owner, repo, tags))

