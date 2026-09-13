# Mobile smoke-test sample

A reusable, portrait-only Godot 4.5 release-export sample. It runs real SDK calls, renders the current result, and persists its progress between app launches. The addon remains dependency-free; this test project intentionally inspects SDK internals to assert queue state and observe HTTP responses. For ordinary app integration, see `../basic_usage.gd`.

## What it tests

Four launches perform 47 assertions per platform:

1. Resource autoload initialization, release-environment metadata, anonymous/session UUIDs, synthetic identification, screen capture, live feature-flag loading, automatic `push_error` capture with GDScript frames, and batch HTTP acknowledgement. One event remains queued.
2. Identity, super properties, and the queued event UUID survive restarting. The queued event is flushed, then opt-out discards another event and blocks capture/flags/flush.
3. Opt-out survives restarting. Opt-in resumes capture and flushing.
4. Opt-in survives restarting, without replaying acknowledged or discarded events.

The app calls `shutdown()` after each stage so backgrounding cannot flush the deliberately retained event. This tests persistence across normal SDK shutdown/app restarts, **not** durability during an abrupt kill in the middle of a filesystem write. It tests logged errors, not native process crashes.

**These calls send real data to the configured project.** A successful run sends six events per platform, including one synthetic person identification and one deliberate error. Events have `sdk_test=true` and a unique `test_run_id`; identities start with `godot-sdk-smoke-`. No groups or real personal data are created. Prefer a development project.

**HTTP 200 is not proof of downstream processing.** PostHog's ingestion acknowledgement precedes error processing. The sample asserts the required custom-frame schema, but final verification in the PostHog UI/backend is a separate check using the printed event UUIDs and `test_run_id`. A project token alone does not grant event-query access.

## Prepare a run

From the repository root, with Python 3, Godot 4.5, and the Android SDK/JDK installed:

```sh
python3 scripts/install_godot.py --mobile-templates

# Create a local test-only signing key once, or reuse the existing one.
mkdir -p dist/mobile-smoke
keytool -genkeypair -keystore dist/mobile-smoke/test.keystore \
  -storepass android -alias androiddebugkey -keypass android \
  -dname 'CN=PostHog SDK Emulator Test' -keyalg RSA -keysize 2048 -validity 3650

# Read without putting the token into shell history.
printf 'PostHog project token: '
read -r -s POSTHOG_API_KEY
printf '\n'
export POSTHOG_API_KEY
python3 scripts/prepare_mobile_smoke.py
unset POSTHOG_API_KEY
```

The preparer defaults to **`https://us.i.posthog.com`**; `--host` supports another region or test server. It prints the new run ID, bundle ID, project path, and output path. Every preparation creates a new directory and bundle ID, leaving earlier apps, reports, and test data intact. Use the same generated project for both platforms.

Only `config.example.tres` with an **empty key** belongs in source control. The actual `config.tres`, copied addon, signing keys, APKs, Xcode builds, and reports belong under ignored `dist/`. Generated run directories also ignore all their contents, including when using a custom `--output`. Never commit an exported application: the project token is embedded in it. Source-local `config.tres`, export settings, and copied `addons/` are ignored as well.

The installer prints `GODOT` and `GODOT_TEMPLATES`. Set `GODOT` to that executable for manual export commands below. Configure the Android SDK/JDK paths in that editor if auto-detection does not find them. Templates must match the editor version.

## Android emulator

```sh
adb devices -l
python3 scripts/run_android_smoke.py \
  dist/mobile-smoke/<run-id>/run.json --device emulator-5554
```

This imports the generated project, makes a signed ARM64 **release** APK, installs it on the explicit device, and performs all four launches. Each stage waits for a report and asserts all checks. It does not clear app data or uninstall the app. Reports, event UUIDs, and logcat output remain in the run's `android/` directory.

The app remains installed on its final portrait PASS screen. Running an already completed app again sends nothing. Prepare a new run to repeat the suite; do not erase existing test data just to reset it.

## iOS Simulator on Apple Silicon

The official Godot 4.5 simulator archive advertises ARM64 but contains only x86_64 objects. Recent iOS simulator runtimes reject those Intel apps. See [the upstream template issue](https://github.com/godotengine/godot/issues/118161). We verified this sample on an iPhone 17 Pro / iOS 26.4 simulator using a locally compiled **Godot 4.5 ARM64 release library**. This is not validation of the official simulator template or of physical iOS devices.

Build the missing library once (Xcode, its simulator SDK, and `uv` are required):

```sh
git clone --depth 1 --branch 4.5-stable \
  https://github.com/godotengine/godot.git .cache/godot/source-4.5
test "$(git -C .cache/godot/source-4.5 rev-parse HEAD)" = \
  876b290332ec6f2e6d173d08162a02aa7e6ca46d || exit 1
(cd .cache/godot/source-4.5 && \
  uvx --from scons==4.9.1 scons platform=ios target=template_release \
  arch=arm64 simulator=yes vulkan=no metal=no opengl3=yes disable_3d=yes \
  optimize=none lto=none debug_symbols=no -j8)
```

This is a reduced 2D/OpenGL simulator test build, not an engine template intended for production distribution. Leave the official cached templates unchanged.

Set `PROJECT` and `OUT` to the paths printed by the preparer, then export the Xcode project:

```sh
mkdir -p "$OUT/ios"
"$GODOT" --headless --path "$PROJECT" --editor --import --quit
"$GODOT" --headless --path "$PROJECT" --export-release 'iOS Smoke' \
  "$OUT/ios/GodotMobileSmoke.xcodeproj"
```

Replace only the generated project's simulator library and correct its advertised architectures:

```sh
export OUT
python3 - <<'PY'
import os, plistlib, shutil
from pathlib import Path
framework = Path(os.environ['OUT']) / 'ios/GodotMobileSmoke.xcframework'
shutil.copyfile(
    '.cache/godot/source-4.5/bin/libgodot.ios.template_release.arm64.simulator.a',
    framework / 'ios-arm64_x86_64-simulator/libgodot.a',
)
path = framework / 'Info.plist'
metadata = plistlib.loads(path.read_bytes())
for library in metadata['AvailableLibraries']:
    if library.get('SupportedPlatformVariant') == 'simulator':
        library['SupportedArchitectures'] = ['arm64']
path.write_bytes(plistlib.dumps(metadata))
PY

xcodebuildmcp simulator list
xcodebuildmcp simulator build-and-run \
  --project-path "$OUT/ios/GodotMobileSmoke.xcodeproj" \
  --scheme GodotMobileSmoke --configuration Release \
  --simulator-id "$SIMULATOR_ID" --derived-data-path "$OUT/ios/DerivedData" \
  --prefer-xcodebuild --extra-args CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

After the screen says `PASS — restart_to_verify_queue`, stop and relaunch **this app** using the bundle ID printed by the preparer:

```sh
xcodebuildmcp simulator stop --simulator-id "$SIMULATOR_ID" --bundle-id "$BUNDLE_ID"
xcodebuildmcp simulator launch-app --simulator-id "$SIMULATOR_ID" --bundle-id "$BUNDLE_ID"
```

Repeat after `restart_to_verify_opt_out` and `restart_to_verify_opt_in`, until `PASS — complete`. Wait for each stage before restarting. Do not erase the simulator or uninstall the app between stages. Reports are saved as `user://smoke-report-0.json` through `smoke-report-3.json` inside the app's data container; they include checks, HTTP results, and full synthetic event payloads. `SMOKE_EVENT`, `SMOKE_CHECK`, and the compact `SMOKE_REPORT` lines are also logged.

The dummy team ID and Android test key are for local testing only. Actual device/App Store builds need your own export/signing settings and separate verification.
