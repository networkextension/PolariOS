---
name: publish-testflight
description: Onboard a new iOS app or ship a new build to TestFlight end-to-end. Creates the ASC bundle ID + app record + distribution provisioning profile (idempotent), bumps build number, archives with manual distribution signing, packages the IPA via ditto (works around the rsync 3.4.1 + xcodebuild exportArchive bug on macOS Sequoia+), uploads via xcrun altool, then runs finalize + optional public-group attach + optional beta-review submission via asc_update_build.py. Use when the user says "publish to TestFlight", "发 TestFlight", "上传新版本", "上架新 app", or similar.
---

# publish-testflight

End-to-end pipeline for getting an iOS app onto TestFlight, whether the app is brand new (first build) or already exists (recurring release).

## When to invoke

The user wants either:

- **First-time onboarding** of a new iOS app — register bundle ID + ASC app record + distribution profile, then ship the first build, OR
- **Recurring release** — bump build number, archive, package, upload to TestFlight

Common phrasings: "publish to TestFlight", "发 testflight", "上传新版本", "上架新 app", "ship a build", "auto-register bundle and push to beta".

## What it does (numbered for clarity)

1. **ASC bundle ID** — `POST /v1/bundleIds` if `filter[identifier]=<bundle-id>` returns empty.
2. **ASC app record** — `POST /v1/apps` if no app with that `bundleId` attribute exists. Requires `--name`, `--sku` (defaults to bundle ID), `--primary-locale` (defaults to `en-US`).
3. **Distribution provisioning profile** — finds an active `IOS_APP_STORE` profile by `--profile-name`; if missing, creates one referencing the bundle ID and *all* DISTRIBUTION certs in the ASC team (so any cert Xcode picks at archive time will work). Downloads the profile and installs it at `~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision`.
4. **Bump build number** — sed-replaces `CURRENT_PROJECT_VERSION` in the target project's `.pbxproj`. Default: current value + 1. Override with `--build-number N`.
5. **Archive** — `xcodebuild archive` with **manual** signing (`CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY=Apple Distribution`, `PROVISIONING_PROFILE_SPECIFIER=<profile-name>`). This avoids the "Cloud signing permission error" / "No profiles for ... were found" failures that hit when the Xcode account session is stale.
6. **Build IPA via `ditto`** — `ditto -c -k --keepParent --sequesterRsrc Payload <name>.ipa`. This bypasses `xcodebuild -exportArchive`, which is broken on macOS Sequoia+ because `/usr/bin/rsync` is now 3.4.1 and no longer accepts Apple's `-E` ("preserve extended attributes") shorthand that xcodebuild still passes.
7. **Upload via `xcrun altool`** — copies the `.p8` to `~/.appstoreconnect/private_keys/AuthKey_<keyid>.p8` (where altool looks for it) and runs `altool --upload-app -f <ipa> --type ios --apiKey ... --apiIssuer ...`.
8. **Post-upload helpers** — delegates to the existing `asc_update_build.py` for:
   - `finalize` — set `usesNonExemptEncryption=false` + en-US `whatsNew` (also polls until the build hits `processingState=VALID`, up to ~20 min)
   - `public-group <name>` — attach to the named TestFlight public group (only if `--public-group` was passed)
   - `submit-review` — submit for Apple beta review (only if `--submit-review` was passed)

## Prerequisites

The skill verifies these and fails early with a clear message if any are missing:

- macOS with Xcode installed (and the iOS SDK matching any connected devices — if `xcodebuild` can't find a destination, install the SDK via Xcode → Settings → Platforms).
- ASC API key (`.p8`) with App Manager role.
- Env vars: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`.
- `TEAM_ID` env var or `--team-id` flag.
- A Python venv with `pyjwt` + `requests` + `cryptography`. Default location: `.publish-venv/bin/python` (matches existing project convention).
- `asc_update_build.py` reachable. Default location: cwd. Override with `--asc-helper`.
- At least one active DISTRIBUTION certificate in the ASC team (cannot be created via API; user has to do this in Xcode → Settings → Accounts → Manage Certificates or in developer.apple.com).
- Xcode scheme that builds `generic/platform=iOS`.

## How to invoke

```bash
cd <repo root>

export ASC_KEY_ID=...
export ASC_ISSUER_ID=...
export ASC_KEY_PATH=~/Downloads/AuthKey_${ASC_KEY_ID}.p8
export TEAM_ID=...

cat > /tmp/whats_new.txt <<EOF
<release notes here, en-US, ≤4000 chars>
EOF

# Always run in background (Bash run_in_background=true) — finalize polls ASC for ~5–20 min.
.publish-venv/bin/python .claude/skills/publish-testflight/publish_testflight.py \
  --bundle-id com.example.myapp \
  --name "MyApp" \
  --scheme MyApp \
  --project MyApp/MyApp.xcodeproj \
  --whats-new /tmp/whats_new.txt \
  --public-group "Public Beta" \
  --submit-review
```

### Polarstart (this repo's defaults)

When working in `/Users/apple/Codex/iOS`, sensible defaults are:

- `--bundle-id com.change.polarstart`
- `--name IdeaMesh`
- `--scheme polarstart`
- `--project polarstart/polarstart.xcodeproj`
- `--profile-name "polarstart iOS App Store"` (already exists in ASC)
- `TEAM_ID=Z9XG3YEP93`
- `ASC_KEY_ID=SAZ8WF9X6U`
- `ASC_ISSUER_ID=69a6de92-f4fa-47e3-e053-5b8c7c11a4d1`
- `ASC_KEY_PATH=~/Downloads/AuthKey_SAZ8WF9X6U.p8`

For a recurring polarstart release, also pass `--skip-onboarding` to short-circuit the ASC create-if-missing steps.

### Internal testers only

Omit `--public-group` *and* `--submit-review`. The build still goes to ASC, internal testers see it once processing finishes. No external visibility.

## When NOT to use this skill

- The user only wants to commit code, push a branch, open a PR, etc. — those don't go through this pipeline.
- The user wants to release a Mac app, watchOS app, or any non-iOS target — script is iOS-only.
- The user wants to *promote* a build that's already on App Store Connect (e.g. attach an existing build to a new group) — those are one-off operations on `asc_update_build.py`, not the full publish chain.

## After running

Report back to the user (matching the level of detail they asked for):

- App + version + build number
- ASC build UUID (from the upload step)
- Final state (e.g. `VALID`, `WAITING_FOR_REVIEW`)
- Public TestFlight link if `--public-group` was used (the helper prints `Public link: https://testflight.apple.com/join/<code>`)

## Files in this skill

- `SKILL.md` — this file
- `publish_testflight.py` — the actual pipeline (idempotent ASC onboarding + archive + IPA + upload + post-upload chain)
