# Building the arm64-v8a APK

ReFreezer has no checked-in build outputs and cannot be built from a plain `git clone` without
preparation (submodules, `lib/.env`, Gradle wrapper). `.github/workflows/build-apk.yml` performs
that preparation on a clean GitHub runner and produces an installable, arm64-v8a only APK.

## Status

| Item | Value |
| --- | --- |
| Workflow | `.github/workflows/build-apk.yml` — "Build APK (arm64-v8a)" |
| Last verified run | [run 42511765494](https://github.com/imilizoprad/refreezer/actions/runs/42511765494) — **success** |
| Artifact | `ReFreezer-arm64-v8a-release` (APK + `SHA256SUMS.txt`, 30 days) |
| APK inside the artifact | `ReFreezer-arm64-v8a-release.apk` |
| Build command | `flutter build apk --release --target-platform android-arm64` (single ABI, no `--split-per-abi`) |

## Getting the APK

1. Open the run: **Actions → Build APK (arm64-v8a) → the run → Artifacts**.
2. Download `ReFreezer-arm64-v8a-release.zip`, unzip it, verify `sha256sum -c SHA256SUMS.txt`.
3. Install: `adb install ReFreezer-arm64-v8a-release.apk`
   (or copy it to the device and open it — sideloading must be allowed).

From a shell with the GitHub CLI:

```bash
gh run download <run-id> -R imilizoprad/refreezer -n ReFreezer-arm64-v8a-release
```

A GitHub release with the APK attached is also produced automatically for `v*` tags, and for manual
runs with the `publish_release` input enabled.

## Triggering a build

* **Manual:** Actions → *Build APK (arm64-v8a)* → *Run workflow*, with inputs
  `flutter_version` (default `3.47.9`; clear it to resolve the newest stable release),
  `build_mode` (`release`/`debug`), `abi` (`arm64-v8a` default) and `publish_release`.
  `workflow_dispatch` only exists once the workflow is present on the default branch.
* **Tag:** pushing a `v*` tag builds and publishes a release.
* **Pull request:** runs when the workflow, `pubspec.yaml`, `lib/**` or `android/**` changes, so a
  broken build shows up in review.

## Signing

Without secrets the APK is signed with an ephemeral CI key: it installs fine, but a later build
cannot update it in place (uninstall first) and it is not a Play-ready artifact. Provide
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_ALIAS`, `ANDROID_KEYSTORE_PASSWORD` and
`ANDROID_KEY_PASSWORD` to sign with a real key instead.

## Secrets

| Secret | Needed for | Without it |
| --- | --- | --- |
| `DEEZER_CLIENT_ID`, `DEEZER_CLIENT_SECRET` | Deezer login/downloads | placeholder keys, login fails |
| `LASTFM_API_KEY`, `LASTFM_API_SECRET` | scrobbling | placeholder keys, scrobbling fails |
| `ANDROID_KEYSTORE_*` (4 values) | stable signing | ephemeral CI key |

## Toolchain the workflow pins

| Component | Version |
| --- | --- |
| Flutter / Dart | 3.47.9 stable / Dart 3.10 |
| JDK | Temurin 17 |
| Gradle | 8.14.3 (`android/gradle/wrapper/gradle-wrapper.properties`) |
| Android Gradle Plugin | 8.11.1 (`android/settings.gradle`) |
| Kotlin | 2.2.20 (`android/settings.gradle`) |
| compileSdk / targetSdk / minSdk | 36 / 35 / 21 |
| NDK | 28.2.13676358 |
| ABI | arm64-v8a |

## What the workflow has to fix up (and why)

These are environment repairs the workflow performs on the runner; they are not part of the app:

* **Submodules** — `custom_navigator`, `equalizer_flutter`, `external_path`,
  `move_to_background` and `scrobblenaut` are `path:` dependencies pinned to third-party commits.
  `actions/checkout` fetches them; the workflow then shims `handleStatusBarTap()` into
  `custom_navigator` (a `WidgetsBindingObserver` member added after that commit) and raises
  `scrobblenaut`'s language-version floor so `json_serializable` (which now emits null-aware
  elements, Dart 3.9+) can generate its `*.g.dart` files.
* **`lib/.env`** — Envied reads it at build time; it is git-ignored, so the workflow writes one
  from secrets (placeholders when unset).
* **Gradle wrapper** — `gradle/wrapper/*` is git-ignored upstream. The workflow regenerates the
  wrapper for the pinned Gradle version and pre-fetches the distribution (the runner's link to
  `services.gradle.org` times out often enough to be a real failure mode).
* **Codegen** — `dart run build_runner build` for the app (Envied, json_serializable) and inside
  `scrobblenaut`.
* **Diagnostics** — on failure the workflow posts the tail of every build log as a pull-request
  comment, because the job log often cannot be downloaded through the API.

## Repository fixes this work required

Building against a current Flutter release surfaced real defects in the app:

* `lib/ui/log_screen.dart` — `DownloadLogViewer` was referenced by the settings screen but never
  implemented; the app did not compile at all. It is now implemented (reads
  `<external files>/download.log`).
* `lib/service/download_controller.dart` — `_lastNotify` was nullable while used as a non-nullable
  argument.
* `lib/settings.dart` — `BottomAppBarTheme` → `BottomAppBarThemeData` (renamed in Flutter 3.35).
* `android/app/src/main/java/r/r/refreezer/DownloadService.java` — `downloadCover()` called
  `JSONObject.getString()` while only declaring `IOException`.
* `android/gradle`, `android/build.gradle`, `android/app/build.gradle` — Gradle 8.12 → 8.14.3,
  AGP 8.10.0 → 8.11.1, Kotlin 2.1.20 → 2.2.20, compileSdk 35 → 36, NDK → 28.2.13676358
  (`sqflite_android` and the `jni` runtime need API 36 symbols). `targetSdk` stays 35.

## Local reproduction

```bash
git clone --recurse-submodules https://github.com/imilizoprad/refreezer.git
cd refreezer
echo "DEEZER_CLIENT_ID=...\nDEEZER_CLIENT_SECRET=...\nLASTFM_API_KEY=...\nLASTFM_API_SECRET=..." > lib/.env
(cd scrobblenaut && flutter pub get && dart run build_runner build)
flutter pub get
dart run build_runner build
cd android && gradle wrapper --gradle-version 8.14.3 && cd ..
flutter build apk --release --target-platform android-arm64
```

The resulting file is `build/app/outputs/flutter-apk/app-release.apk`.
