# ReFreezer — Development Status

**Branch:** `arena/f4b6f150-refreezer` (from `master` @ `2bb8009`)
**Last updated:** 2026-11-08
**Current phase:** Phase One — Complete repository audit (**DONE**) · Phase Two — UI/UX evaluation (**documented as analysis in `PROJECT_AUDIT.md` §5; `UI_UX_AUDIT.md` not yet produced — awaiting go-ahead**)

Status labels: **DONE** (verified) · **IN PROGRESS** · **BLOCKED** (needs input/environment) · **UNVERIFIED** (implemented, not adequately tested).

---

## 1. Phase status

| Phase | Scope | Status |
|---|---|---|
| 1 — Repository audit | Read all sources, map architecture/features, identify defects, write the five audit documents | **DONE** (static audit; runtime verification BLOCKED — see §4) |
| 2 — Product & UX evaluation | Screen-by-screen UX assessment; design system proposal | **IN PROGRESS** — findings captured in `PROJECT_AUDIT.md` §5 and `FEATURES_INVENTORY.md` §2-3. Dedicated `UI_UX_AUDIT.md` deliberately not created yet (first task was Phase One only) |
| 3 — Architectural improvement | Proposal + decisions | **DONE (proposal)** — `ARCHITECTURE.md` §8, `UPGRADE_ROADMAP.md` M6 |
| 4 — Implementation | Milestones M0–M8 | **NOT STARTED** — awaiting approval of D1–D8 (`UPGRADE_ROADMAP.md` §4) |
| 5 — QA | Tests, device matrix | **BLOCKED** — no toolchain/emulator (§4) |
| 6 — Release readiness | Build config, docs, signing | **NOT STARTED** (assessed in `UPGRADE_ROADMAP.md` M8) |

---

## 2. Completed work

**Documents created (this turn)**

| File | Purpose |
|---|---|
| `PROJECT_AUDIT.md` | Full audit report: purpose, architecture summary, journeys, problems (19 ranked defects), UX, performance, security, recommendations, roadmap summary, complexity/risk, method |
| `ARCHITECTURE.md` | Runtime topology, module map with LOC, navigation, state, error handling, persistence, coupling hot-spots, target architecture + ADR-lite decisions (A1–A10), guardrails |
| `FEATURES_INVENTORY.md` | Feature matrix by area with verification status, screen inventory, settings inventory, journeys with friction, feature gaps |
| `BUGS_AND_TECHNICAL_DEBT.md` | 21 defects (BUG-01…BUG-21) with evidence/impact/fix/verification + 18 debt items (TD-01…TD-18) + prioritised fix order |
| `UPGRADE_ROADMAP.md` | M0–M8 with objectives, affected files, work items, acceptance criteria, risks, estimates, approval gates (D1–D8), verification artefacts, non-goals |
| `DEVELOPMENT_STATUS.md` | This file |
| `CHANGELOG.md` | Documentation-only baseline entry |

**Application code changed:** none. No files under `lib/`, `android/`, `assets/` or `translations/` were modified. No features added or removed. No backend contract touched.

---

## 3. Key findings (one-screen summary)

1. **The product is feature-rich and the feature work is largely real** — streaming, downloads, tagging, offline, lyrics, Android Auto/TV, 31 locales.
2. **The failure mode is "silent or fatal":** unreachable error branches, uncaught async crashes from `late` locals, unguarded JSON loads that brick startup, no HTTP timeouts, no crash reporting.
3. **Security:** unauthenticated loopback audio server (P0), plaintext ARL/Spotify secrets (P0/P1), global cleartext traffic, unverified self-update.
4. **Verifiability:** zero tests, no CI, no lockfile, empty submodules, missing `.env`/`env.g.dart` → cannot build a fresh clone; nothing can be trusted until M0.
5. **UX:** no design system (four duplicated `ThemeData`s, ~90 literal font sizes), three loading idioms, one empty state in the whole app, `fluttertoast` as the feedback mechanism, destructive actions without confirmations, dead "Visualizer" toggle.
6. **Performance:** eager queue resolution, 250 ms player-bar rebuilds, non-virtualised lists with per-tile subscriptions, full-size palette extraction.

---

## 4. Blockers

| ID | Blocker | Impact | What is needed |
|---|---|---|---|
| BLK-01 | **No Flutter/Dart/Java/Android SDK in the environment**; `storage.googleapis.com`, `pub.dev`, `services.gradle.org` unreachable (only GitHub/npm/PyPI allowed) | `flutter pub get`, `dart format`, `flutter analyze`, `flutter test`, `flutter build`, emulator runs — all impossible | Provision a toolchain image (Flutter 3.32.x, JDK 17, Android SDK 35, NDK 27.0.12077973) with package-host access, or run the documented commands on a workstation/CI |
| BLK-02 | **5 git submodules are empty** (`custom_navigator`, `equalizer_flutter`, `external_path`, `move_to_background`, `scrobblenaut`) | Cannot resolve path dependencies; build/tests cannot start even with a toolchain | Network access to `github.com` for `git submodule update --init` (GitHub *is* reachable here, so this can be attempted during M0) |
| BLK-03 | **`lib/.env` and `lib/utils/env.g.dart` absent (git-ignored)** | `envied` class does not exist → compile error; requires Deezer + Last.fm API keys | Owner-supplied credentials in `lib/.env` (never commit) + `dart run build_runner build`; plus an `.env.example` for contributors |
| BLK-04 | **No runtime device/API access** | Playback, downloads, permissions, Android Auto/TV, offline behaviour, real Deezer responses — all UNVERIFIED | Emulator/device with a test Deezer account |
| BLK-05 | **Approval needed** for decisions D1–D8 (submodule strategy, one secure-storage dependency, removal of dead features/settings, storage strategy, distribution target, design direction) | Determines M2/M3/M4/M8 scope | Owner sign-off |

---

## 5. Tests executed

**Automated Dart/Flutter tests:** none exist in the repository (`test/` directory absent). None could be run (BLK-01).

**Verification actually performed** (static; reproducible with the scripts described):

| Check | Method | Result |
|---|---|---|
| Source inventory | `find`/`wc -l` | 227 tracked files; 31,667 Dart LOC (11,176 translations → ~20.5k real), 3,139 Java LOC |
| Dependency usage | cross-reference `pubspec.yaml` deps vs `package:` imports | 3 unused deps (`animations`, `encrypt`, `pointycastle`); 2 commented-out imports (`flutter_file_dialog`, `restart_app`) |
| Declared assets vs disk | path check | 0 missing declared assets; 6 code-referenced assets also declared (no gaps) |
| i18n key coverage | parse `.i18n` literals vs `en_us.dart` | **11 missing** English keys; 16 stale/unmatched keys |
| Locale coverage | per-locale key intersection with `en-US` (357 keys) | 31 locales, median 99.4 %; **`ur-PK` 3.9 %**, **`te-IN` 7.8 %** |
| Generated code vs models | compare `*.g.dart` to annotated fields | No drift detected in `cache.g.dart`, `settings.g.dart`, `definitions.g.dart` |
| Dead code | import/usage search | `utils/blowfish.dart` (1,170 LOC) unused; `utils/math_utils.dart` unused; 5 of 7 routes unused; `Settings.proxyAddress` unused; `QueueState.empty` unused |
| Manifest/permission review | read `AndroidManifest.xml` + permission calls | `POST_NOTIFICATIONS` commented out while requested at startup; `MANAGE_EXTERNAL_STORAGE` + `requestLegacyExternalStorage` + `usesCleartextTraffic=true` |
| CI/test presence | directory inspection | No workflows; no tests |
| Defect confirmation | targeted source reading with line references | 21 defects documented, each with file:line evidence |

**Not executed (BLOCKED):** `dart format`, `flutter analyze`, `dart run build_runner build`, `flutter test`, `flutter build apk`/`aab`, `adb`/emulator runs, any real API call.

---

## 6. Files modified

**Added:** `PROJECT_AUDIT.md`, `ARCHITECTURE.md`, `FEATURES_INVENTORY.md`, `BUGS_AND_TECHNICAL_DEBT.md`, `UPGRADE_ROADMAP.md`, `DEVELOPMENT_STATUS.md`, `CHANGELOG.md`.
**Modified:** none. **Deleted:** none.
**Git:** documentation committed on `arena/f4b6f150-refreezer` only.

---

## 7. Important decisions

| Decision | Reason |
|---|---|
| Audit statically instead of claiming tool results | No SDK/package-host access; fabricating `flutter analyze` output would violate the "never claim something works without testing it" rule |
| No code changes in Phase One | Explicit instruction; also prevents unverifiable churn prior to M0 |
| Defer `UI_UX_AUDIT.md` | Phase One was scoped first; UX findings are captured in `PROJECT_AUDIT.md` §5 so nothing is lost, and the dedicated document will be produced when Phase Two is approved |
| Recommend no framework adoption (Riverpod/Bloc) | 59 dependencies already; `ChangeNotifier`/`ValueNotifier` covers the five shared-state needs with zero new deps |
| Keep `custom_navigator`, `audio_service`, Java download service | Load-bearing for TV focus, media session and file integrity; replacements are high-risk with no user benefit |
| Sequence security (M2) after crash containment (M1) | M1 is cheaper and reduces the chance that M2's process-boundary changes are conflated with unrelated crashes; both are patch-release sized |

---

## 8. Next steps (recommended order)

1. **Clear BLK-01/02/03** (toolchain + submodules + `.env`) so M0 can actually be executed and verified.
2. **Approve D1–D8** (or confirm defaults) — especially D2 (secure-storage dependency) and D3 (remove dead Visualizer toggle).
3. **Execute M0** (lockfile, bootstrap script, CI, i18n checker, toolchain docs) — first milestone that converts this audit into a verified baseline.
4. Then M1 (crash containment) as the first user-visible patch release.

Until a build and a device run are available, every behavioural statement in these documents stays labelled **VERIFIED (static)** or **UNVERIFIED (runtime)**.
