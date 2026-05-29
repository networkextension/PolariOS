#!/usr/bin/env python3
"""
asc_renew_profile.py — regenerate an iOS App Store provisioning profile
that's gone stale because the local distribution cert was rotated.

Usage:
  ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=... \
    asc_renew_profile.py <bundle-id> <profile-name>

It will:
  1. Find the bundle ID record.
  2. Pick the latest valid DISTRIBUTION certificate on the account.
  3. Delete any existing profile with <profile-name>.
  4. Create a fresh IOS_APP_STORE profile bundling that cert.
  5. Download the .mobileprovision into
     ~/Library/MobileDevice/Provisioning Profiles/<uuid>.mobileprovision

Auth uses the same ASC API key triple as asc_update_build.py.
"""

import base64
import os
import sys
import time
import uuid as uuidlib
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
PROFILES_DIR = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"


def make_token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    key_path = Path(os.environ["ASC_KEY_PATH"]).expanduser()
    private_key = key_path.read_text()
    now = int(time.time())
    payload = {
        "iss": issuer,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(
        payload,
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def make_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({
        "Authorization": f"Bearer {make_token()}",
        "Accept": "application/json",
        "Content-Type": "application/json",
    })
    return s


def raise_with_body(r: requests.Response) -> None:
    if not r.ok:
        try:
            print(r.json(), file=sys.stderr)
        except Exception:
            print(r.text, file=sys.stderr)
        r.raise_for_status()


def find_bundle_id(s: requests.Session, identifier: str) -> str:
    r = s.get(f"{API}/v1/bundleIds", params={
        "filter[identifier]": identifier,
        "limit": 200,
    }, timeout=30)
    raise_with_body(r)
    data = r.json().get("data", [])
    for row in data:
        if row.get("attributes", {}).get("identifier") == identifier:
            return row["id"]
    raise SystemExit(f"bundle id {identifier} not found on account")


def find_distribution_cert(s: requests.Session) -> str:
    r = s.get(f"{API}/v1/certificates", params={
        "filter[certificateType]": "DISTRIBUTION",
        "limit": 200,
    }, timeout=30)
    raise_with_body(r)
    rows = r.json().get("data", [])
    if not rows:
        raise SystemExit("no DISTRIBUTION certificate on account")
    # Most recent first.
    rows.sort(
        key=lambda d: d.get("attributes", {}).get("expirationDate", ""),
        reverse=True,
    )
    chosen = rows[0]
    attrs = chosen["attributes"]
    print(f"using cert: {attrs.get('name')} (exp {attrs.get('expirationDate')})",
          file=sys.stderr)
    return chosen["id"]


def find_profile_by_name(s: requests.Session, name: str):
    r = s.get(f"{API}/v1/profiles", params={
        "filter[name]": name,
        "limit": 200,
    }, timeout=30)
    raise_with_body(r)
    for row in r.json().get("data", []):
        if row.get("attributes", {}).get("name") == name:
            return row
    return None


def delete_profile(s: requests.Session, profile_id: str) -> None:
    r = s.delete(f"{API}/v1/profiles/{profile_id}", timeout=30)
    if r.status_code not in (204, 200):
        raise_with_body(r)
    print(f"deleted stale profile {profile_id}", file=sys.stderr)


def create_profile(s: requests.Session, name: str, bundle_id: str,
                   cert_id: str) -> dict:
    body = {
        "data": {
            "type": "profiles",
            "attributes": {
                "name": name,
                "profileType": "IOS_APP_STORE",
            },
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {
                    "data": [{"type": "certificates", "id": cert_id}],
                },
            },
        }
    }
    r = s.post(f"{API}/v1/profiles", json=body, timeout=30)
    raise_with_body(r)
    return r.json()["data"]


def download_profile(s: requests.Session, profile_id: str) -> bytes:
    r = s.get(f"{API}/v1/profiles/{profile_id}", params={
        "fields[profiles]": "profileContent,uuid,name",
    }, timeout=30)
    raise_with_body(r)
    attrs = r.json()["data"]["attributes"]
    content = attrs.get("profileContent")
    if not content:
        raise SystemExit("profile created but profileContent missing")
    return base64.b64decode(content), attrs.get("uuid") or str(uuidlib.uuid4())


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    bundle = sys.argv[1]
    profile_name = sys.argv[2]

    s = make_session()
    bid = find_bundle_id(s, bundle)
    cert_id = find_distribution_cert(s)

    existing = find_profile_by_name(s, profile_name)
    if existing:
        delete_profile(s, existing["id"])

    new_profile = create_profile(s, profile_name, bid, cert_id)
    blob, profile_uuid = download_profile(s, new_profile["id"])

    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    out = PROFILES_DIR / f"{profile_uuid}.mobileprovision"
    out.write_bytes(blob)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
