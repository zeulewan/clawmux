#!/usr/bin/env python3
"""
testflight-sync.py — Add new Xcode Cloud builds to TestFlight internal beta groups.

Checks for VALID builds not yet in the beta group, sets export compliance if
needed, and adds them. Run via cron every 5 minutes.

Apps:
  WebFinder  — 6759476914  → group 49a42d58-dc58-499c-bab0-06f3d3ebe0b6
  ClawMux    — 6760262353  → group 7530051a-0156-43ab-ab1d-eedf68d6ffd1
"""

import jwt
import time
import urllib.request
import urllib.error
import json
import sys

KEY_PATH   = "/tmp/AuthKey_V946Q6Y2C6.p8"
KEY_ID     = "V946Q6Y2C6"
ISSUER_ID  = "83d4f7b8-f022-4571-a182-b03813d3e5bc"

APPS = [
    {
        "name":       "WebFinder",
        "app_id":     "6759476914",
        "group_id":   "49a42d58-dc58-499c-bab0-06f3d3ebe0b6",
    },
    {
        "name":       "ClawMux",
        "app_id":     "6760262353",
        "group_id":   "7530051a-0156-43ab-ab1d-eedf68d6ffd1",
    },
]

BASE = "https://api.appstoreconnect.apple.com/v1"


def make_token():
    key = open(KEY_PATH).read()
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, key, algorithm="ES256", headers={"kid": KEY_ID})


def api(token, method, path, body=None):
    url = BASE + path if path.startswith("/") else path
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            err = json.loads(raw)
        except Exception:
            err = {"raw": raw.decode(errors="replace")}
        return {"_error": e.code, "_body": err}


def sync_app(token, app):
    name     = app["name"]
    app_id   = app["app_id"]
    group_id = app["group_id"]

    # Builds already in the beta group
    in_group = set()
    path = f"/betaGroups/{group_id}/builds?limit=200"
    while path:
        d = api(token, "GET", path)
        for b in d.get("data", []):
            in_group.add(b["id"])
        path = d.get("links", {}).get("next")

    # All VALID builds for the app
    new_builds = []
    path = f"/builds?filter%5Bapp%5D={app_id}&limit=200"
    while path:
        d = api(token, "GET", path)
        for b in d.get("data", []):
            if b["attributes"].get("processingState") == "VALID" and b["id"] not in in_group:
                new_builds.append(b)
        path = d.get("links", {}).get("next")

    if not new_builds:
        print(f"[{name}] nothing new")
        return

    for b in new_builds:
        bid = b["id"]
        ver = b["attributes"].get("version", "?")

        # Set export compliance if not set
        if b["attributes"].get("usesNonExemptEncryption") is None:
            r = api(token, "PATCH", f"/builds/{bid}", {
                "data": {
                    "type": "builds",
                    "id": bid,
                    "attributes": {"usesNonExemptEncryption": False},
                }
            })
            if "_error" in r:
                print(f"[{name}] v{ver}: compliance FAILED {r}", file=sys.stderr)
                continue
            print(f"[{name}] v{ver}: set export compliance")

        # Add to beta group
        r = api(token, "POST", f"/betaGroups/{group_id}/relationships/builds", {
            "data": [{"type": "builds", "id": bid}]
        })
        if "_error" in r:
            print(f"[{name}] v{ver}: add to group FAILED {r}", file=sys.stderr)
        else:
            print(f"[{name}] v{ver}: added to TestFlight")


def main():
    token = make_token()
    for app in APPS:
        sync_app(token, app)


if __name__ == "__main__":
    main()
