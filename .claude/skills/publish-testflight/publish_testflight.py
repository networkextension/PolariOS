#!/usr/bin/env python3
"""Onboard a new iOS app or ship a new TestFlight build end-to-end.

Pipeline:
  1. ASC bundle ID — create if missing
  2. ASC app record — create if missing
  3. Distribution provisioning profile — create + install locally
  4. Bump CURRENT_PROJECT_VERSION in .pbxproj
  5. Archive with manual distribution signing
  6. Build IPA via ditto (avoids xcodebuild exportArchive's rsync 3.4.1 bug)
  7. Upload via xcrun altool
  8. Poll ASC for build processing (via existing asc_update_build.py)
  9. Finalize: usesNonExemptEncryption=false + en-US whatsNew
 10. Optional: attach to TestFlight public group
 11. Optional: submit for Apple beta review
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"


def make_token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    key_path = Path(os.environ["ASC_KEY_PATH"]).expanduser()
    private_key = key_path.read_text()
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, private_key, algorithm="ES256",
                      headers={"kid": key_id, "typ": "JWT"})


def make_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"Authorization": f"Bearer {make_token()}",
                      "Content-Type": "application/json"})
    return s


# ── ASC onboarding ──────────────────────────────────────────────────────

def ensure_bundle_id(s: requests.Session, identifier: str, display_name: str) -> str:
    r = s.get(f"{API}/bundleIds?filter[identifier]={identifier}")
    r.raise_for_status()
    data = r.json().get("data", [])
    if data:
        bid = data[0]["id"]
        print(f"✓ Bundle ID exists: {identifier} → {bid}")
        return bid

    print(f"  Creating bundle ID {identifier}…")
    r = s.post(f"{API}/bundleIds", json={
        "data": {
            "type": "bundleIds",
            "attributes": {
                "identifier": identifier,
                "name": display_name,
                "platform": "IOS",
            },
        }
    })
    if r.status_code not in (200, 201):
        raise SystemExit(f"Bundle ID create failed: {r.status_code} {r.text}")
    bid = r.json()["data"]["id"]
    print(f"✓ Created bundle ID: {identifier} → {bid}")
    return bid


def ensure_app(s: requests.Session, bundle_identifier: str, bid_resource_id: str,
               name: str, sku: str, primary_locale: str) -> str:
    # List apps (filter[bundleId] takes the resource id, but listing is safer)
    r = s.get(f"{API}/apps?limit=200&fields[apps]=bundleId,name")
    r.raise_for_status()
    for app in r.json().get("data", []):
        if app["attributes"].get("bundleId") == bundle_identifier:
            print(f"✓ App exists: {bundle_identifier} → id={app['id']} "
                  f"name={app['attributes'].get('name')}")
            return app["id"]

    print(f"  Creating ASC app: name={name} sku={sku}…")
    r = s.post(f"{API}/apps", json={
        "data": {
            "type": "apps",
            "attributes": {
                "bundleId": bundle_identifier,
                "name": name,
                "primaryLocale": primary_locale,
                "sku": sku,
            },
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bid_resource_id}},
            },
        }
    })
    if r.status_code not in (200, 201):
        raise SystemExit(f"App create failed: {r.status_code} {r.text}")
    app_id = r.json()["data"]["id"]
    print(f"✓ Created app: {name} → {app_id}")
    return app_id


def ensure_distribution_profile(s: requests.Session, bid_resource_id: str,
                                profile_name: str) -> Path:
    r = s.get(f"{API}/bundleIds/{bid_resource_id}/profiles"
              "?fields[profiles]=name,profileType,profileState,uuid&limit=50")
    r.raise_for_status()
    target = None
    for p in r.json().get("data", []):
        a = p["attributes"]
        if (a.get("profileType") == "IOS_APP_STORE"
                and a.get("profileState") == "ACTIVE"
                and a.get("name") == profile_name):
            target = p
            break

    if not target:
        cr = s.get(f"{API}/certificates?limit=200")
        cr.raise_for_status()
        cert_ids = [c["id"] for c in cr.json().get("data", [])
                    if c["attributes"].get("certificateType") == "DISTRIBUTION"]
        if not cert_ids:
            raise SystemExit(
                "No DISTRIBUTION certificates in ASC team. Create one via Xcode → "
                "Settings → Accounts → Manage Certificates, or in developer.apple.com."
            )

        print(f"  Creating profile '{profile_name}' "
              f"with {len(cert_ids)} distribution cert(s)…")
        r = s.post(f"{API}/profiles", json={
            "data": {
                "type": "profiles",
                "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bid_resource_id}},
                    "certificates": {
                        "data": [{"type": "certificates", "id": c} for c in cert_ids],
                    },
                },
            }
        })
        if r.status_code not in (200, 201):
            raise SystemExit(f"Profile create failed: {r.status_code} {r.text}")
        target = r.json()["data"]
        print(f"✓ Created profile: {profile_name} (id={target['id']})")
    else:
        print(f"✓ Profile exists: {profile_name} (id={target['id']})")

    profile_id = target["id"]
    uuid = target["attributes"]["uuid"]
    r = s.get(f"{API}/profiles/{profile_id}"
              "?fields[profiles]=name,uuid,profileContent")
    r.raise_for_status()
    raw = base64.b64decode(r.json()["data"]["attributes"]["profileContent"])
    dest_dir = Path.home() / "Library/MobileDevice/Provisioning Profiles"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{uuid}.mobileprovision"
    dest.write_bytes(raw)
    print(f"  Installed: {dest}")
    return dest


# ── Xcode ───────────────────────────────────────────────────────────────

def current_build_number(pbxproj: Path) -> int:
    text = pbxproj.read_text()
    m = re.search(r"CURRENT_PROJECT_VERSION = ([0-9]+);", text)
    return int(m.group(1)) if m else 0


def bump_build_number(pbxproj: Path, build_number: int) -> str:
    text = pbxproj.read_text()
    new_text = re.sub(r"CURRENT_PROJECT_VERSION = [0-9]+;",
                      f"CURRENT_PROJECT_VERSION = {build_number};", text)
    pbxproj.write_text(new_text)
    m = re.search(r"MARKETING_VERSION = ([^;]+);", new_text)
    marketing = m.group(1) if m else "1.0"
    print(f"✓ Bumped → MARKETING_VERSION={marketing}  "
          f"CURRENT_PROJECT_VERSION={build_number}")
    return marketing


def archive(project: Path, scheme: str, archive_path: Path,
            team_id: str, profile_name: str) -> None:
    print(f"  Archiving {scheme}…")
    cmd = [
        "xcodebuild", "archive",
        "-project", str(project),
        "-scheme", scheme,
        "-destination", "generic/platform=iOS",
        "-archivePath", str(archive_path),
        "-allowProvisioningUpdates",
        "CODE_SIGN_STYLE=Manual",
        f"DEVELOPMENT_TEAM={team_id}",
        f"PROVISIONING_PROFILE_SPECIFIER={profile_name}",
        "CODE_SIGN_IDENTITY=Apple Distribution",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout[-4000:])
        sys.stderr.write(r.stderr[-2000:])
        raise SystemExit("Archive failed")
    print(f"✓ Archive: {archive_path}")


# ── IPA (bypasses xcodebuild's broken rsync -E IPA step) ────────────────

def build_ipa(archive_path: Path, ipa_path: Path) -> None:
    app_src = archive_path / "Products" / "Applications"
    apps = list(app_src.glob("*.app"))
    if not apps:
        raise SystemExit(f"No .app in {app_src}")
    app = apps[0]

    work = ipa_path.parent / "_payload-tmp"
    if work.exists():
        shutil.rmtree(work)
    payload = work / "Payload"
    payload.mkdir(parents=True)
    subprocess.check_call(["cp", "-R", str(app), str(payload / app.name)])

    if ipa_path.exists():
        ipa_path.unlink()
    subprocess.check_call([
        "ditto", "-c", "-k", "--keepParent", "--sequesterRsrc",
        str(payload), str(ipa_path),
    ])
    shutil.rmtree(work)
    print(f"✓ IPA: {ipa_path} ({ipa_path.stat().st_size} bytes)")


# ── Upload ──────────────────────────────────────────────────────────────

def upload_ipa(ipa_path: Path) -> None:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    key_src = Path(os.environ["ASC_KEY_PATH"]).expanduser()
    key_dest_dir = Path.home() / ".appstoreconnect" / "private_keys"
    key_dest_dir.mkdir(parents=True, exist_ok=True)
    key_dest = key_dest_dir / f"AuthKey_{key_id}.p8"
    if not key_dest.exists():
        shutil.copy(key_src, key_dest)

    print(f"  Uploading {ipa_path}…")
    r = subprocess.run([
        "xcrun", "altool", "--upload-app",
        "-f", str(ipa_path),
        "--type", "ios",
        "--apiKey", key_id,
        "--apiIssuer", issuer,
        "--show-progress",
    ])
    if r.returncode != 0:
        raise SystemExit("Upload failed")
    print("✓ Upload succeeded")


# ── Post-upload (delegate to existing asc_update_build.py) ──────────────

def post_upload(asc_helper: Path, venv_python: Path, bundle_id: str,
                marketing: str, build_number: int, whats_new_file: Path,
                public_group: str | None, submit_review: bool) -> None:
    def run(*args: str) -> None:
        print(f"\n→ {' '.join(args)}")
        r = subprocess.run([str(venv_python), str(asc_helper), *args])
        if r.returncode != 0:
            raise SystemExit(f"Helper step '{args[0]}' failed")

    run("finalize", bundle_id, marketing, str(build_number), str(whats_new_file))
    if public_group:
        run("public-group", bundle_id, marketing, str(build_number), public_group)
    if submit_review:
        run("submit-review", bundle_id, marketing, str(build_number))


# ── Main ────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(
        description="Onboard + publish iOS app to TestFlight")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--name", required=True,
                   help="App display name (used if app/bundle ID not yet created)")
    p.add_argument("--scheme", required=True)
    p.add_argument("--project", required=True,
                   help="Path to .xcodeproj (the directory itself)")
    p.add_argument("--team-id", default=os.environ.get("TEAM_ID"))
    p.add_argument("--sku", help="ASC SKU (defaults to bundle ID)")
    p.add_argument("--primary-locale", default="en-US")
    p.add_argument("--build-number", type=int,
                   help="Build number (default: current pbxproj value + 1)")
    p.add_argument("--profile-name",
                   help="Provisioning profile name (default: '<scheme> iOS App Store')")
    p.add_argument("--whats-new", required=True,
                   help="Path to en-US whatsNew text file")
    p.add_argument("--public-group",
                   help="Attach to TestFlight public group; omit for internal-only")
    p.add_argument("--submit-review", action="store_true",
                   help="Submit for Apple beta review after upload")
    p.add_argument("--asc-helper", default="asc_update_build.py")
    p.add_argument("--venv-python", default=".publish-venv/bin/python")
    p.add_argument("--skip-onboarding", action="store_true",
                   help="Skip bundle/app/profile creation (assume they exist)")
    p.add_argument("--build-dir", default="build")
    args = p.parse_args()

    if not args.team_id:
        raise SystemExit("TEAM_ID required (env var or --team-id)")
    for var in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
        if var not in os.environ:
            raise SystemExit(f"{var} not set")

    project_path = Path(args.project).resolve()
    pbxproj = project_path / "project.pbxproj"
    if not pbxproj.is_file():
        raise SystemExit(f"Not a project.pbxproj: {pbxproj}")

    build_dir = Path(args.build_dir).resolve()
    build_dir.mkdir(parents=True, exist_ok=True)
    archive_path = build_dir / f"{args.scheme}-iOS.xcarchive"
    ipa_path = build_dir / f"{args.scheme}.ipa"

    whats_new_path = Path(args.whats_new).resolve()
    if not whats_new_path.is_file():
        raise SystemExit(f"whatsNew file missing: {whats_new_path}")

    profile_name = args.profile_name or f"{args.scheme} iOS App Store"
    sku = args.sku or args.bundle_id

    asc_helper = Path(args.asc_helper).resolve()
    if not asc_helper.is_file():
        raise SystemExit(f"asc_update_build.py not found: {asc_helper}")
    venv_python = Path(args.venv_python).resolve()
    if not venv_python.is_file():
        raise SystemExit(f"venv python not found: {venv_python}")

    s = make_session()

    if not args.skip_onboarding:
        print("\n══ ASC Onboarding ══")
        bid_rid = ensure_bundle_id(s, args.bundle_id, args.name)
        ensure_app(s, args.bundle_id, bid_rid, args.name, sku, args.primary_locale)
        ensure_distribution_profile(s, bid_rid, profile_name)
    else:
        print("\n══ Skipping onboarding ══")

    print("\n══ Bump build ══")
    build_number = (args.build_number if args.build_number is not None
                    else current_build_number(pbxproj) + 1)
    marketing = bump_build_number(pbxproj, build_number)

    print("\n══ Archive ══")
    archive(project_path, args.scheme, archive_path, args.team_id, profile_name)

    print("\n══ Build IPA (ditto, bypass xcodebuild rsync bug) ══")
    build_ipa(archive_path, ipa_path)

    print("\n══ Upload ══")
    upload_ipa(ipa_path)

    print("\n══ Post-upload ══")
    post_upload(
        asc_helper=asc_helper,
        venv_python=venv_python,
        bundle_id=args.bundle_id,
        marketing=marketing,
        build_number=build_number,
        whats_new_file=whats_new_path,
        public_group=args.public_group,
        submit_review=args.submit_review,
    )

    print(f"\n══ DONE: {args.name} {marketing}({build_number}) ══")


if __name__ == "__main__":
    main()
