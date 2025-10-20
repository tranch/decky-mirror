#!/usr/bin/env python3
import argparse
import base64
import re
import sys
import urllib.parse


def b64decode_pad(s: str) -> bytes:
    # Add missing padding if necessary
    pad = (-len(s)) % 4
    return base64.urlsafe_b64decode(s + ("=" * pad))


def parse_line(line: str):
    line = line.strip()
    if not line or not line.startswith("ss://"):
        return None

    uri = line
    # Extract name tag if present
    name = ""
    if "#" in uri:
        uri, frag = uri.split("#", 1)
        name = urllib.parse.unquote(frag)

    body = uri[len("ss://") :]
    # Case 1: base64(method:pwd)@host:port
    if "@" in body and not re.search(r"://", body):
        userinfo, at_host = body.split("@", 1)
        # userinfo could be "method:pwd" or BASE64(method:pwd)
        try:
            # try base64 first
            up = b64decode_pad(userinfo).decode("utf-8")
            if ":" in up:
                method, pwd = up.split(":", 1)
            else:
                # If not "method:pwd", fallback to literal
                raise ValueError
        except Exception:
            # fallback to literal userinfo
            if ":" not in userinfo:
                return None
            method, pwd = userinfo.split(":", 1)

        # host:port
        if ":" not in at_host:
            return None
        host, port = at_host.rsplit(":", 1)

    else:
        # Case 2: entire body is base64("method:pwd@host:port") — rare but seen
        try:
            decoded = b64decode_pad(body).decode("utf-8")
        except Exception:
            return None
        # decoded like: method:pwd@host:port
        if "@" not in decoded or ":" not in decoded:
            return None

        try:
            cred, at_host = decoded.split("@", 1)
            if ":" not in cred:
                cred = b64decode_pad(cred).decode("utf-8")
            method, pwd = cred.split(":", 1)
            host, port = at_host.rsplit(":", 1)
        except ValueError:
            print(f"Failed to parse decoded SS URI: {decoded}", file=sys.stderr)
            return None

    method = urllib.parse.unquote(method)
    pwd = urllib.parse.unquote(pwd)
    host = host.strip("[]")  # allow IPv6 in brackets

    ss_uri = (
        f"ss://{urllib.parse.quote(method)}:{urllib.parse.quote(pwd)}@{host}:{port}"
    )
    return ss_uri, (name or f"{host}:{port}")


def main():
    ap = argparse.ArgumentParser(
        description="Parse base64 SS subscription and select one node"
    )
    ap.add_argument("--subscription-b64", required=True,
                    help="The base64-encoded subscription content")
    ap.add_argument("--name-regex", default="",
                    help="Pick first node whose name matches this regex")
    ap.add_argument("--index", type=int, default=0,
                    help="Fallback index if regex not provided or not matched",)
    args = ap.parse_args()

    # Subscription itself is base64 of a text with multiple lines of URLs (ss://...)
    sub_raw = b64decode_pad(args.subscription_b64).decode("utf-8", errors="ignore")
    lines = [ln for ln in sub_raw.splitlines() if ln.strip()]

    nodes = []
    for ln in lines:
        parsed = parse_line(ln.strip())
        if parsed:
            nodes.append(parsed)

    if not nodes:
        print("No valid ss nodes found in subscription", file=sys.stderr)
        sys.exit(2)

    selected = None
    if args.name_regex:
        pat = re.compile(args.name_regex)
        for item in nodes:
            if pat.search(item[1]):
                selected = item
                break

    if selected is None:
        idx = min(max(args.index, 0), len(nodes) - 1)
        selected = nodes[idx]

    ss_uri, name = selected
    print(f"{ss_uri}|{name}")


if __name__ == "__main__":
    main()

