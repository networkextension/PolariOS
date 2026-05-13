#!/usr/bin/env python3
"""App Store Connect helpers for post-upload TestFlight automation.

Subcommands:
  finalize      set usesNonExemptEncryption=false and en-US whatsNew
  public-group  create-or-update a public beta group and attach the build
  submit-review submit the build for beta app review
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
POLL_SECONDS = 15
POLL_MAX_ATTEMPTS = 80  # ~20 minutes；ASC /builds filter 有时偏慢，不是上传问题
PROCESSED_POLL_MAX = 80  # ~20 minutes for processingState → VALID
WHATS_NEW_LIMIT = 4000


# ── Auth ──────────────────────────────────────────────────────────────
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
    token = make_token()
    s = requests.Session()
    s.headers.update(
        {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }
    )
    return s


# ── Low-level HTTP ────────────────────────────────────────────────────
def get(session: requests.Session, path: str, **params) -> dict:
    r = session.get(f"{API}{path}", params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def raise_with_body(r: requests.Response) -> None:
    if not r.ok:
        try:
            print("  ASC response:", r.json(), file=sys.stderr)
        except Exception:
            print("  ASC raw:", r.text, file=sys.stderr)
    r.raise_for_status()


# ── Lookups ───────────────────────────────────────────────────────────
def find_app(session: requests.Session, bundle_id: str) -> str:
    data = get(session, "/apps", **{"filter[bundleId]": bundle_id})["data"]
    if not data:
        raise SystemExit(f"No app found for bundleId={bundle_id}")
    return data[0]["id"]


def find_build(
    session: requests.Session, app_id: str, version: str, build_number: str
) -> dict | None:
    params = {
        "filter[app]": app_id,
        "filter[preReleaseVersion.version]": version,
        "filter[version]": build_number,
        "limit": 1,
    }
    data = get(session, "/builds", **params)["data"]
    return data[0] if data else None


def wait_for_build(
    session: requests.Session, app_id: str, version: str, build_number: str
) -> str:
    for attempt in range(1, POLL_MAX_ATTEMPTS + 1):
        build = find_build(session, app_id, version, build_number)
        if build:
            return build["id"]
        print(
            f"  … build {version}({build_number}) not visible yet "
            f"(attempt {attempt}/{POLL_MAX_ATTEMPTS})"
        )
        time.sleep(POLL_SECONDS)
    raise SystemExit(
        f"Build {version}({build_number}) did not appear within "
        f"{POLL_SECONDS * POLL_MAX_ATTEMPTS}s"
    )


def wait_for_valid(session: requests.Session, build_id: str) -> None:
    for attempt in range(1, PROCESSED_POLL_MAX + 1):
        state = get(session, f"/builds/{build_id}")["data"]["attributes"][
            "processingState"
        ]
        if state == "VALID":
            print(f"✓ Build {build_id} is VALID")
            return
        if state in ("FAILED", "INVALID"):
            raise SystemExit(f"Build processingState={state}, aborting")
        print(
            f"  … build processingState={state} "
            f"(attempt {attempt}/{PROCESSED_POLL_MAX})"
        )
        time.sleep(POLL_SECONDS)
    raise SystemExit(
        f"Build {build_id} did not reach VALID within "
        f"{POLL_SECONDS * PROCESSED_POLL_MAX}s"
    )


# ── finalize: compliance + whatsNew ───────────────────────────────────
def set_compliance(
    session: requests.Session, build_id: str, uses_non_exempt: bool
) -> None:
    r = session.patch(
        f"{API}/builds/{build_id}",
        json={
            "data": {
                "type": "builds",
                "id": build_id,
                "attributes": {"usesNonExemptEncryption": uses_non_exempt},
            }
        },
        timeout=30,
    )
    raise_with_body(r)
    print(f"✓ Set usesNonExemptEncryption={uses_non_exempt} on build {build_id}")


def upsert_locale(
    session: requests.Session, build_id: str, locale: str, whats_new: str
) -> None:
    whats_new = whats_new[:WHATS_NEW_LIMIT]
    locs = get(
        session, f"/builds/{build_id}/betaBuildLocalizations"
    )["data"]
    for loc in locs:
        if loc["attributes"].get("locale") == locale:
            r = session.patch(
                f"{API}/betaBuildLocalizations/{loc['id']}",
                json={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": loc["id"],
                        "attributes": {"whatsNew": whats_new},
                    }
                },
                timeout=30,
            )
            raise_with_body(r)
            print(f"✓ Updated {locale} whatsNew on build {build_id}")
            return

    r = session.post(
        f"{API}/betaBuildLocalizations",
        json={
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": whats_new},
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
        timeout=30,
    )
    raise_with_body(r)
    print(f"✓ Created {locale} whatsNew on build {build_id}")


# ── public-group ──────────────────────────────────────────────────────
def find_beta_group_by_name(
    session: requests.Session, app_id: str, name: str
) -> dict | None:
    params = {"filter[app]": app_id, "filter[name]": name, "limit": 1}
    data = get(session, "/betaGroups", **params)["data"]
    return data[0] if data else None


def create_public_group(
    session: requests.Session, app_id: str, name: str
) -> dict:
    r = session.post(
        f"{API}/betaGroups",
        json={
            "data": {
                "type": "betaGroups",
                "attributes": {
                    "name": name,
                    "publicLinkEnabled": True,
                },
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}}
                },
            }
        },
        timeout=30,
    )
    raise_with_body(r)
    return r.json()["data"]


def attach_build_to_group(
    session: requests.Session, group_id: str, build_id: str
) -> None:
    r = session.post(
        f"{API}/betaGroups/{group_id}/relationships/builds",
        json={"data": [{"type": "builds", "id": build_id}]},
        timeout=30,
    )
    raise_with_body(r)
    print(f"✓ Attached build {build_id} to group {group_id}")


# ── submit-review ─────────────────────────────────────────────────────
def submit_for_review(session: requests.Session, build_id: str) -> dict:
    r = session.post(
        f"{API}/betaAppReviewSubmissions",
        json={
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
        timeout=30,
    )
    raise_with_body(r)
    return r.json()["data"]


# ── Commands ──────────────────────────────────────────────────────────
def cmd_finalize(args: argparse.Namespace) -> int:
    whats_new = Path(args.whats_new_file).read_text().strip()
    if not whats_new:
        whats_new = f"Build {args.version} ({args.build_number})"
    session = make_session()
    app_id = find_app(session, args.bundle_id)
    print(f"✓ App: {args.bundle_id} → {app_id}")
    build_id = wait_for_build(session, app_id, args.version, args.build_number)
    print(f"✓ Build: {args.version}({args.build_number}) → {build_id}")
    set_compliance(session, build_id, uses_non_exempt=False)
    upsert_locale(session, build_id, "en-US", whats_new)
    return 0


def cmd_public_group(args: argparse.Namespace) -> int:
    session = make_session()
    app_id = find_app(session, args.bundle_id)
    print(f"✓ App: {args.bundle_id} → {app_id}")
    build_id = wait_for_build(session, app_id, args.version, args.build_number)
    wait_for_valid(session, build_id)

    existing = find_beta_group_by_name(session, app_id, args.name)
    if existing:
        group = existing
        attrs = group["attributes"]
        print(f"✓ Group exists: {group['id']} (publicLinkEnabled={attrs.get('publicLinkEnabled')})")
        if not attrs.get("publicLinkEnabled"):
            r = session.patch(
                f"{API}/betaGroups/{group['id']}",
                json={
                    "data": {
                        "type": "betaGroups",
                        "id": group["id"],
                        "attributes": {"publicLinkEnabled": True},
                    }
                },
                timeout=30,
            )
            raise_with_body(r)
            group = r.json()["data"]
            print(f"✓ Enabled public link on group {group['id']}")
    else:
        group = create_public_group(session, app_id, args.name)
        print(f"✓ Created group {group['id']} (\"{args.name}\")")

    attach_build_to_group(session, group["id"], build_id)

    link = group["attributes"].get("publicLink")
    if not link:
        # Re-fetch to pick up the link Apple auto-assigns post-create
        group = get(session, f"/betaGroups/{group['id']}")["data"]
        link = group["attributes"].get("publicLink")
    print(f"Public link: {link}")
    return 0


def cmd_submit_review(args: argparse.Namespace) -> int:
    session = make_session()
    app_id = find_app(session, args.bundle_id)
    print(f"✓ App: {args.bundle_id} → {app_id}")
    build_id = wait_for_build(session, app_id, args.version, args.build_number)
    wait_for_valid(session, build_id)
    sub = submit_for_review(session, build_id)
    print(f"✓ Submitted for review (submission id={sub['id']}, state={sub['attributes'].get('betaReviewState')})")
    return 0


# ── CLI ───────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(description="ASC helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("bundle_id")
    common.add_argument("version")
    common.add_argument("build_number")

    p_final = sub.add_parser("finalize", parents=[common])
    p_final.add_argument("whats_new_file")
    p_final.set_defaults(func=cmd_finalize)

    p_group = sub.add_parser("public-group", parents=[common])
    p_group.add_argument("name", help="beta group name, e.g. 'Public Beta'")
    p_group.set_defaults(func=cmd_public_group)

    p_review = sub.add_parser("submit-review", parents=[common])
    p_review.set_defaults(func=cmd_submit_review)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
