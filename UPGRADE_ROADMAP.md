# ReFreezer — Upgrade Roadmap

**Baseline:** `2bb8009` / v0.7.15 · **Roadmap owner:** engineering (this engagement)
**Principle:** smallest change that measurably improves the product; every milestone ends with `dart format`, `flutter analyze`, tests, and a documented verification result.

> Phase One did not implement any of the following. Each milestone requires sign-off before implementation (see §4).

---

## 0. How milestones are sequenced

```
M0 harness ──▶ M1 crash containment ──▶ M2 security ──▶ M3 UX foundation ──▶ M4 core-flow polish ──▶ M5 performance ──▶ M6 architecture seam ──▶ M7 a11y/i18n ──▶ M8 release
                    │                        │                 │                      │
                    └── tests added here ────┴─── regression safety net ──────────────┘
```

* M0 must come first: nothing else can be verified without a build.
* M1/M2 are surgical and independent of design work; they can ship as patch releases (`0.7.16`, `0.7.17`).
* M3 creates the components M4 depends on. Do not start M4 before M3's `AsyncView`/tokens are in place.
* M5 measures the M4 result. M6 moves logic only after tests exist. M7/M8 certify.

---

## M0 — Reproducible build & verification harness

**Objective:** any engineer (and CI) can clone, build, analyse and test deterministically.

**Affected files:** `pubspec.yaml`, `pubspec.lock` (new, tracked), `.gitignore`, `.gitmodules`, `lib/utils/env.dart` + new `lib/.env.example`, new `.github/workflows/ci.yml`, `README.md`, `run_build_runner.ps1` (or replace with `tool/bootstrap.sh`), `analysis_options.yaml`.

**Work**
1. Commit `pubspec.lock` (remove from `.gitignore`); pin `disk_space_plus` to a commit SHA instead of a branch.
2. Resolve the 5 submodules: keep them but pin SHAs, **or** vendor them as `packages/` if the forks are unmaintained (decision needed by owner). Document which.
3. Add `lib/.env.example` with placeholder keys; keep `.env` ignored; document `envied` generation; make `env.g.dart` generation part of bootstrap, and fail with a clear message (not a compile error) if `.env` is missing.
4. Add `tool/bootstrap.sh` (POSIX) equivalent of `run_build_runner.ps1`.
5. Add CI: `flutter pub get`, `dart format --output=none --set-exit-if-changed`, `flutter analyze --fatal-infos`, `flutter test`, `flutter build apk --debug` (cached), plus a job that runs the i18n-coverage script.
6. Add the i18n checker script (used for this audit) under `tool/checks/i18n_coverage.dart` + a 0-missing-keys gate.
7. Document exact toolchain (Flutter version, JDK 17, Android SDK, NDK 27.0.12077973, Gradle 8.12).

**Acceptance**
- Fresh clone → documented commands → green `analyze`, `test`, debug APK on a clean machine.
- CI runs on PRs; build time recorded.
- No secrets committed; `.env.example` only.

**Risk:** submodule forks may be needed for Gradle 8 compatibility — if pinning breaks, fall back to vendoring (bigger diff, but reproducible).
**Estimate:** 1–2 days.

---

## M1 — Crash & data-integrity containment (patch release)

**Objective:** eliminate the "silent or fatal" failure mode without UI redesign.

**Affected files:** `lib/main.dart`, `lib/api/cache.dart`, `lib/settings.dart`, `lib/api/deezer.dart` (+ new `lib/core/` helpers), `lib/ui/search.dart`, `lib/ui/library.dart`, `lib/ui/downloads_screen.dart`, `lib/ui/lyrics.dart`, `lib/ui/details_screens.dart`, `android/.../DownloadsDatabase.java`.

**Work**
1. `core/json_store.dart`: versioned, atomic (tmp+rename), `.bak` recovery, typed failure. Migrate settings/cache/home/queue persistence. **BUG-03**
2. `core/api_client.dart`: timeouts, typed errors, one retry for GETs, `AppFailure` mapping. Route `deezer.dart`, `deezer_login.dart`, `spotify.dart`, `updater.dart` through it. **BUG-06**
3. Fix unreachable error states and `late` crashes (**BUG-04, BUG-05**), empty-list indexing (**BUG-14**), null-safe comparators (**BUG-13**).
4. `mounted` discipline: fix every `setState`-after-await, enable/keep `use_build_context_synchronously` (**BUG-16**).
5. Global error plumbing: `FlutterError.onError`, `PlatformDispatcher.instance.onError` → log + non-fatal toast in debug; `ErrorWidget.builder` that shows a friendly panel in release (**TD-13**).
6. `DownloadsDatabase` real migrations (**BUG-08**).
7. Add tests: JSON store (corrupt/partial/old), comparators, `Version`, filename templating, cache round-trip.

**Acceptance**
- App starts normally with truncated/typed-wrong `settings.json`, `metacache.json`, `homescreen.json`, `playback.json`.
- Search shows an error + Retry when offline; typing suggestions offline does not crash.
- `flutter analyze` clean; new unit tests green.
- No behavioural regressions in manual smoke list (login, home, search, library, play, download).

**Risk:** touching persistence can lose user data if migration is wrong → write migration tests first, keep `.bak`, do not delete originals until success.
**Estimate:** 2–3 days.

---

## M2 — Security hardening (patch release)

**Objective:** close the P0/P1 security findings with contained changes.

**Affected files:** `android/.../StreamServer.java`, `MainActivity.java`, `android/app/src/main/AndroidManifest.xml`, new `res/xml/network_security_config.xml`, `lib/service/audio_service.dart`, new `lib/platform/stream_server.dart`, new `lib/data/secure_store.dart`, `lib/settings.dart`, `lib/ui/settings_screen.dart`, `lib/ui/updater.dart`.

**Work**
1. Stream server: ephemeral port, per-launch token segment, 403 without token; `startServer` returns `{port, token}` or throws; `StreamUrlResolver` consumes it; player shows a recoverable error if the server cannot start (**BUG-01, BUG-07**).
2. `network_security_config.xml`: cleartext permitted only for `127.0.0.1`/`localhost`; drop blanket `usesCleartextTraffic`.
3. Credentials → Keystore-backed store with one-time migration and re-login fallback; `allowBackup=false` or exclusion rules (**BUG-02**). *Requires approval for one new dependency (e.g. `flutter_secure_storage`).*
4. Updater: HTTPS only, `Content-Length` guard, throttled progress, SHA-256 verification against a value published in the release body/asset, Wi-Fi-only preference (**BUG-17**).
5. Manifest hygiene: `POST_NOTIFICATIONS` declared (and requested at a sensible moment with rationale, not before first frame); `MANAGE_EXTERNAL_STORAGE` reviewed against SAF (**decision needed, see §4**).

**Acceptance**
- `curl` from another app/browser on device returns 403 without the token; playback works.
- Token no longer present in `settings.json`; fresh login and migrated login both work.
- `adb backup`/file inspection does not reveal credentials.
- Analyzer + tests green; changelog notes the required re-login for existing users if migration fails.

**Risk:** touching the two-process boundary and player URL construction can break playback on some devices → coordinate, test on ≥2 API levels (21/29/34) and one Android Auto receiver if available.
**Estimate:** 2–3 days.

---

## M3 — UX foundation (design system + state components)

**Objective:** one visual language and one loading/empty/error pattern, so every later screen change is consistent and cheap.

**Affected files:** new `lib/app/theme/` (`tokens.dart`, `theme_factory.dart`), new `lib/ui/design_system/` (`async_view.dart`, `empty_state.dart`, `section_header.dart`, `app_sheet.dart`, `app_button.dart`, `spacing.dart`), `lib/settings.dart` (theme getters delegate to factory), `lib/ui/elements.dart`, `lib/main.dart`, `lib/ui/home_screen.dart`, `lib/ui/search.dart` (as first consumers).

**Work**
1. Tokens: colour roles (surface, surfaceVariant, accent, accentOn, danger, success, muted), spacing scale (4/8/12/16/24/32), radius scale, type scale (display/title/body/label with 5 roles), elevation/border tokens. Dark + light; four themes expressed as **token sets**, not four `ThemeData` copies (**TD-02**).
2. `ThemeFactory.build(tokens)` → single `ThemeData`; keep the existing look as the default token set (no visual redesign by default; optional refinement per screen is a separate, reviewed change).
3. `AsyncView<T>`: `loading` (skeleton row/shimmer), `empty` (icon + title + optional action), `error` (message + Retry), `data`. Replaces all three current idioms (**TD-06**).
4. Standard components: section header, list tile wrapper, action sheet (with destructive styling + confirmation helper), primary/secondary buttons, snackbar/toast helper with a single API.
5. Navigation: typed routes + `onGenerateRoute`, tab-aware deep links; keep `custom_navigator` and existing back semantics (**TD-07**). Document route map.
6. TV/focus: extract the hand-rolled traversal into a `TvFocusScope` helper, keeping the current behaviour as a baseline test.

**Acceptance**
- All new code uses tokens/`AsyncView`; screens migrated so far show identical layout in the four themes.
- `flutter analyze` clean, golden tests for `AsyncView` states and both themes.
- Screenshot comparison on phone portrait/landscape + tablet before/after (no unintended visual change).

**Risk:** theme refactor can subtly change every screen → golden tests and screenshot review; migrate a small set of screens first.
**Estimate:** 5–7 days.

---

## M4 — Core-flow polish

**Objective:** make Home, Search, Library, Details, Player, Lyrics and Settings feel deliberate, with correct states and no dead ends.

**Affected files:** `lib/ui/home_screen.dart`, `search.dart`, `library.dart`, `details_screens.dart`, `player_screen.dart`, `player_bar.dart`, `lyrics.dart`, `menu.dart`, `downloads_screen.dart`, `settings_screen.dart`, plus new per-feature controllers.

**Work**
1. **Home:** cached-first render with a visible "updating" state, pull-to-refresh, error with retry, skeleton rows, section-level graceful degradation (skip malformed sections instead of failing the page).
2. **Search:** real error/empty/retry states, paginated "show all", suggestion error tolerance, search history management (clear all / remove), offline banner.
3. **Library:** correct sorting (null-safe, stable), filters (all/offline), virtualised lists, loading + empty states per section, optimistic favourite updates shared with Search/Details, pull-to-refresh (**BUG-12, BUG-13, BUG-14**).
4. **Details:** header with sticky actions, disc grouping retained, "Library/Offline/Download" wording clarified (`Add to library`, `Save offline`, `Download to device`) with a one-line explanation sheet, error/retry, no full-screen spinner for a cached entity.
5. **Player:** fixes for timer/rebuild/focus (**BUG-10, BUG-11**), queue with drag handles and an explicit "playing" indicator, clear queue confirmation, error banner when playback fails, artwork fallback for missing art (**BUG-20**).
6. **Lyrics:** remove the dead visualizer toggle (**BUG-09** — requires feature-removal approval), single timer, visible "no lyrics" state, tap-to-seek affordance.
7. **Settings:** group with section headers, add search, add "reset section to defaults", replace dead settings, remove "might be buggy" copy (**BUG-19**), confirmation for destructive actions (**BUG-15**).
8. **Downloads:** empty state, confirmation for "clear all", out-of-space pre-check with message, per-item retry, session summary ("3 downloaded, 1 failed").

**Acceptance**
- Manual smoke matrix (below) passes on API 21/29/34 + TV emulator.
- Every screen has defined loading/empty/error states; no infinite spinners under a network-off test.
- Widget tests for `AsyncView` consumers and the sort/filter logic.

**Risk:** breadth. Ship per screen (one PR per area) with the same acceptance checklist to keep review tractable.
**Estimate:** 7–10 days.

---

## M5 — Performance

**Objective:** responsive lists, fast playback start, low idle cost.

**Affected files:** `lib/service/audio_service.dart` (queue building), `lib/ui/tiles.dart`, `lib/ui/library.dart`, `lib/ui/player_screen.dart`, `lib/ui/cached_image.dart`, `lib/ui/downloads_screen.dart`.

**Work**
1. Lazy queue resolution: resolve the current item + N-ahead window, resolve-on-demand for the rest; keep `just_audio` sequencing semantics intact; prefetch next track (**TD-08**).
2. Replace per-tile subscriptions/offline lookups with a shared `PlaybackSummary`/`OfflineIndex` notifier (**BUG-12**).
3. `ListView.builder` + `itemExtent` where possible; remove nested scrollables on Home.
4. Image policy: `memCacheWidth`/`maxWidth` per tile size; pick thumbnail resolution by density; palette extraction on a downscaled image; cache extracted colours per track ID.
5. Player: no rebuilds while paused/idle; gradient/blur work debounced.
6. Startup: move non-critical init (update check, preload cache, Last.fm auth) after first frame; measure cold start.

**Acceptance**
- 1000-track favourites: scroll at 60 fps on a mid-range device (macrobenchmark/profile), first sound within ~1 s of tapping play (from ~3–5 s), no leak growth after 10 minutes.
- DevTools: PlayerBar rebuild count ≈ 0 when paused.

**Risk:** queue laziness interacts with shuffle indices and fallback tracks — implement behind a flag, keep the eager path until verified on device.
**Estimate:** 3–4 days.

---

## M6 — Architecture seam & cleanup

**Objective:** move logic out of widgets now that tests exist; delete dead weight.

**Affected files:** new `lib/data/repositories/*`, `lib/core/connectivity.dart`, `lib/features/*` controllers, deletions (`lib/utils/blowfish.dart`, `lib/utils/math_utils.dart`, unused routes), `pubspec.yaml` (drop `animations`, `encrypt`, `pointycastle`).

**Work**
1. Repositories: `DeezerRepository`, `LibraryRepository`, `DownloadRepository`, `SettingsRepository`, `CacheRepository` — thin wrappers over existing code, returning `Result<T>`.
2. Shared state providers: playback summary, library snapshot, downloads, connectivity/offline, settings — `ChangeNotifier`/`ValueNotifier` (no new framework, ADR A5).
3. Connectivity as a provider (replace one-shot `checkConnectivity` snapshots), with a global offline banner.
4. Split oversized files (`settings_screen.dart`, `library.dart`, `details_screens.dart`, `audio_service.dart`) by feature/widget.
5. Remove dead code and unused deps; document the Dart↔Java contract in `docs/native_bridge.md` (**TD-10, TD-11, TD-18**).
6. Keep behaviour identical — this milestone is verified by M1/M4 tests, not new features.

**Acceptance**
- Same manual smoke matrix; test count grows; no screen imports a global singleton except services.
- `flutter analyze` clean; binary size documented before/after.

**Risk:** broad churn with no visible payoff; timebox and stop when the seams above exist.
**Estimate:** 5–8 days.

---

## M7 — Accessibility, localisation and resilience

**Objective:** usable by TalkBack/large-text users; honest translations; graceful degradation offline.

**Affected files:** design system components, all screens (semantics pass), `lib/languages/en_us.dart`, `translations/` scripts, `lib/translations.i18n.dart`, `lib/ui/error.dart`, `lib/service/audio_service.dart` (offline playback messaging).

**Work**
1. Semantics pass: label all icon-only actions, explicit-content and offline indicators, announce playback changes, ensure focus order on TV, minimum 48 dp targets, content descriptions for art.
2. Contrast guard for user-chosen accent colour (auto-adjust text/icon colour); test with all four themes.
3. Text scaling to 200 %: replace fixed heights with intrinsic sizing where text is inside containers.
4. i18n: add the 11 missing strings, sync Crowdin, mark/hide locales below 80 % coverage, RTL audit for `ar`/`he`/`ur`, plural-aware review of strings with counts.
5. Offline resilience: cached-first on all browse surfaces, explicit offline indicators, retry everywhere, no infinite spinners.

**Acceptance**
- TalkBack walkthrough of the five main journeys without unexplained elements.
- 200 % font scale: no clipped text on Home/Search/Library/Player/Settings.
- i18n coverage check: 0 missing keys; low-coverage locales marked.
**Estimate:** 2–3 days.

---

## M8 — Release readiness

**Objective:** produce a release an engineer can sign, build, verify and support — without exposing secrets.

**Affected files:** `pubspec.yaml` (version + build number), `android/app/build.gradle` (versioning from pubspec, R8), `proguard-rules.pro` (new), `android/app/src/main/ic_launcher-playstore.png` / icon assessment, `README.md`, new `docs/RELEASE.md`, `docs/TECHNICAL.md`, `CHANGELOG.md`, `DEVELOPMENT_STATUS.md`.

**Work**
1. Versioning: `version: 0.8.0+<build>`; single source of truth for `versionName`/`versionCode`; documented bump policy.
2. Build config: enable `minifyEnabled`/`shrinkResources` with R8 rules for `jaudiotagger`, `nanohttpd`, `audio_service`, `just_audio`; verify release APK runs (tagging + playback + downloads).
3. Signing: document `key.properties`/JKS creation and CI secret injection; never commit keys (already ignored — verify).
4. Icon/splash assessment: adaptive icon coverage (3 variants), monochrome layer, splash using the brand colour and correct `windowBackground` (currently white → flash; fix in `styles.xml`).
5. Update channel: define how APKs are published (GitHub releases with per-ABI assets and a SHA-256 in the release body) so M2's verification works.
6. Documentation: `README` (features, build, permissions rationale, disclaimer), `docs/TECHNICAL.md` (architecture, bridge contract, storage layout, error taxonomy), `docs/RELEASE.md` (checklist), `CHANGELOG.md` per release.
7. Store-policy assessment (document, do not attempt): `MANAGE_EXTERNAL_STORAGE`, self-update, Deezer branding → distribution via GitHub/F-Droid is the realistic channel. **Ask before any Play submission work.**

**Acceptance**
- Signed release AAB/APKs built from CI; install → login → play → download → update flow verified on device.
- No secrets in repo; `git grep` for keys/tokens clean.
- Docs reviewed; changelog accurate.

**Estimate:** 2–4 days.

---

## 4. Decisions and approvals required

| # | Decision | Why it needs the owner | Default if no answer |
|---|---|---|---|
| D1 | Submodules: pin SHAs vs vendor into `packages/` | Changes repo layout and maintenance ownership | Pin SHAs |
| D2 | Add one dependency for secure storage (`flutter_secure_storage`) | "Avoid unnecessary dependencies" — this one is necessary for BUG-02 | Use Android Keystore via a small custom channel (more code, no dependency) |
| D3 | Remove the dead Visualizer toggle (feature removal) | Explicit approval required before removing features | Keep it but hide behind "Experimental" + fix division by zero |
| D4 | Remove dead settings (`proxyAddress`) and unused deps (`animations`, `encrypt`, `pointycastle`, dead Blowfish file) | Removal of unused surface | Keep, documented as deprecated |
| D5 | Storage strategy: keep `MANAGE_EXTERNAL_STORAGE` vs migrate to SAF/MediaStore | Affects download UX and Play eligibility; touching file storage risks user data | Keep current behaviour, document risk |
| D6 | Whether to change any Deezer request shape (backend contract) | Out of scope without approval | No contract changes |
| D7 | Distribution target (GitHub/F-Droid/Play) | Determines M8 scope and permissions policy | GitHub releases |
| D8 | Design direction for M3 (keep current look as baseline vs refresh) | Product decision; affects screenshots and effort | Keep current look, fix consistency only |

---

## 5. Verification artefacts to be produced per milestone

* `dart format` result, `flutter analyze` output (0 issues), `flutter test` output (count + pass), build output.
* Manual smoke matrix result: API 21 / 29 / 34, phone + tablet + TV emulator; offline mode; permission-denied path; corrupt-state path.
* Screenshots for UI milestones (before/after) at 100 % and 200 % text scale.
* Updated `CHANGELOG.md`, `DEVELOPMENT_STATUS.md`, and (where relevant) `ARCHITECTURE.md`/`BUGS_AND_TECHNICAL_DEBT.md` statuses.
* Honest labels: **DONE** (verified), **UNVERIFIED** (implemented, untested), **BLOCKED** (needs input/environment).

---

## 6. Explicit non-goals

* Rewriting the Java download/decryption stack or the `audio_service` integration.
* Changing Deezer API usage, or adding new streaming/download backends.
* Introducing analytics, ads, accounts, or paid services.
* A full visual rebrand (unless D8 says otherwise).
* iOS/desktop support.
* Play Store submission (documented as an assessment only).
