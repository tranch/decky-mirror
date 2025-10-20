import os, re, subprocess, logging
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse

app = FastAPI(title="Mini GH Releases Mirror")

logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s %(levelname)s %(message)s',
                    datefmt='%Y-%m-%d %H:%M:%S')
logger = logging.getLogger("uvicorn.error")


GIT_ROOT = Path(os.getenv("GIT_ROOT", "/srv/git"))
CGIT_BASE = os.getenv("CGIT_BASE", "https://decky.mirror.example.com")
KEEP_N = int(os.getenv("KEEP_N", "3"))

# SemVer like: v1.2.3 or 1.2.3 (no pre-release/meta)
SEMVER_RE = re.compile(r"^[vV]?\d+\.\d+\.\d+$")

def list_tags(owner: str, repo: str) -> list[str]:
    """List all tags for a bare mirror, newest-first by version (desc)."""
    git_dir = GIT_ROOT / owner / f"{repo}.git"
    if not git_dir.is_dir():
        raise FileNotFoundError(git_dir)

    # Get all tags (names only). Fallback if no taggerdate available.
    out = subprocess.check_output(
        ["git", f"--git-dir={git_dir}", "for-each-ref",
         "--format=%(refname:strip=2)", "refs/tags"],
        text=True
    )
    tags = [t.strip() for t in out.splitlines() if t.strip()]
    # Filter stable (no '-' -> no pre-release)
    stable = [t for t in tags if SEMVER_RE.match(t)]
    # Sort like SemVer descending (Python's sort doesn't know semver; -V comes from coreutils,
    # so here we split by '.' and compare tuples; 'v' prefix removed)
    def norm(t: str):
        t = t[1:] if t.lower().startswith("v") else t
        major, minor, patch = t.split(".")
        return (int(major), int(minor), int(patch))
    stable.sort(key=norm, reverse=True)
    return stable

def make_releases(owner: str, repo: str, tags: list[str]) -> list[dict]:
    """Build a GitHub-compatible releases array; each has one asset pointing to cgit snapshot."""
    releases = []
    for tag in tags[:KEEP_N]:
        asset_name = f"{repo}-{tag}.tar.gz"
        asset_url = f"{CGIT_BASE}/{owner}/{repo}/snapshot/{asset_name}"
        releases.append({
            "tag_name": tag,
            "prerelease": False,
            "assets": [
                {
                    "name": asset_name,
                    "browser_download_url": asset_url,
                }
            ],
        })
    return releases

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.get("/repos/{owner}/{repo}/releases")
def releases(owner: str, repo: str):
    try:
        tags = list_tags(owner, repo)
    except FileNotFoundError as e:
        logger.warning(f"Repo not found: {e}")
        raise HTTPException(status_code=404, detail="repo not found")
    return JSONResponse(make_releases(owner, repo, tags))

