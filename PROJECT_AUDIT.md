# ReFreezer — Project Audit (Phase One)

**Repository:** `imilizoprad/refreezer` (fork of `DJDoubleD/ReFreezer`)
**Audited commit:** `2bb8009` (`master`, 2025-06-11)
**Audit branch:** `arena/f4b6f150-refreezer`
**App version:** `0.7.15` (no build number)
**Platform in scope:** Android (Flutter 3.x / Dart 3.x, `compileSdk 35`, `minSdk 21`, `targetSdk 35`)
**Audit date:** 2026-11-08

---

## 0. Executive summary

ReFreezer is a mature, feature-dense **Deezer client** (streaming + downloading + offline playback + Android Auto + Android TV + lyrics + Last.fm scrobbling + Spotify/Tidal-style library import). It is not a toy: ~20k lines of hand-written Dart, ~3.1k lines of Java, a native download service in a separate process, a native audio-decryption/streaming layer, and 31 locales.

It is also **structurally fragile in ways that the UI does not hide well**:

* No automated tests, no CI, no `pubspec.lock` — nothing prevents regressions.
* Pervasive `setState` + global mutable singletons (`settings`, `cache`, `deezerAPI`, `downloadManager`) and global function variables (`updateTheme`, `logOut`) instead of state management.
* **Unreachable error handling**: search results can never show an error, only spin forever (`search.dart:523-531`).
* **Uncaught async crashes** from `late` locals that are never assigned when a request fails (`search.dart:121`, `library.dart:393`).
* **Local HTTP server with no authentication** (fixed port 36958) serving the user's offline library to any local requester.
* A shipped "Visualizer" feature that is wired into the UI but whose implementation is commented out.
* Fresh-clone builds are impossible: 5 submodules are uninitialised, `lib/.env` and `lib/utils/env.g.dart` are git-ignored, and `pubspec.lock` is ignored.
* i18n drift: 11 user-visible strings are missing English entries (so they stay English in every language), and two locales offered in the picker are <8 % translated.

**Verdict:** the product concept and feature surface are strong; the *engineering chassis* (error handling, state, testing, build reproducibility) is the bottleneck to "production quality". The recommended path is not a rewrite — it is containment + hardening + a thin architecture seam, delivered in small, verifiable milestones.

### Verification statement (important)

This audit is **static**. The sandbox has **no Flutter/Dart/Java/Android SDK**, and the package hosts (`pub.dev`, `storage.googleapis.com`, `services.gradle.org`) are unreachable, so `flutter pub get`, `flutter analyze`, `dart format`, `flutter test` and `flutter build` **could not be executed**. Items are explicitly labelled:

| Label | Meaning |
|---|---|
| **VERIFIED (static)** | Confirmed by reading source and/or scripted checks over the repo (documented in §11). |
| **UNVERIFIED (runtime)** | Reasoned from code but requires a device/emulator to confirm. |
| **BLOCKED** | Cannot be assessed in this environment (see `DEVELOPMENT_STATUS.md`). |

---

## 1. What this application actually does

ReFreezer is an **alternative client for Deezer** that talks to Deezer's private web APIs (`gw-light.php`) and GraphQL "pipe" API, using a user-supplied **ARL cookie** (or email/password, or an in-app browser login) for authentication.

Functional scope:

1. **Discovery** — Deezer home page (sections/rows/grids), Flow, mood/theme channels, search (tracks/albums/artists/playlists/shows/episodes) with suggestions and a persisted search history.
2. **Detail screens** — album, artist (top tracks, albums, related artists, discography pagination), playlist (with pagination + sorting), show/episode.
3. **Playback** — `just_audio` + `audio_service` media session, queue management (add, play next, reorder, shuffle, repeat), sleep timer, saved/restored queue, connectivity-dependent quality (mobile vs Wi-Fi), FLAC/320/128, offline-file playback, fallback-track handling.
4. **Downloads** — native `DownloadService` in a separate process: multi-threaded downloads, tagging (ID3/FLAC via `jaudiotagger`), artwork embedding, `.nomedia`, filename templating, album/artist/disc playlists folders, external storage (SAF/`MANAGE_EXTERNAL_STORAGE`), notifications, and a "private/offline" library stored in app-private storage.
5. **Offline library** — SQLite (`offline2.db` in Dart, `downloads` DB in Java) plus a file-based offline store with its own search/lookup.
6. **Lyrics** — synchronized (GraphQL pipe API) with auto-scroll + tap-to-seek, unsynced fallback, legacy GW API fallback.
7. **Integrations** — Last.fm scrobbling, Deezer listen logging, Spotify/Tidal playlist import (HTML scraping + OAuth), update checker (GitHub releases → APK install).
8. **Platform surface** — Android Auto media browser, Android TV/DPAD focus handling, quick actions (Flow / Favorites shortcuts), launch icons (3 selectable icon aliases), display refresh-rate selection, multiple themes + Google Fonts.
9. **Personalisation** — 31 languages (Crowdin-generated), theme/colour/icon/font, gradient or blurred player background, "colour from album art".

**Legal/ethical posture:** README states it is for educational/private use, uses Deezer's internal APIs without endorsement. This matters for release decisions (see §7 and `UPGRADE_ROADMAP.md` M8): the app cannot be published on Google Play as-is (`MANAGE_EXTERNAL_STORAGE`, `REQUEST_INSTALL_PACKAGES`, self-updating APK, Deezer trademark/branding).

---

## 2. Current architecture

Full detail in `ARCHITECTURE.md`. Condensed:

```
┌────────────────────────────────────────────── Flutter UI isolate ──────────────────────────────────────────────┐
│ main.dart  ── ReFreezerApp (theme/i18n) ── LoginMainWrapper (login gate) ── MainScreen (3 tabs + PlayerBar)     │
│                 │                                    │                                                        │
│                 │ Navigator (root)                   └─ CustomNavigator (per-tab stack, custom_navigator pkg)  │
│                 ├── HomeScreen / SearchScreen / LibraryScreen (each owns a Scaffold + AppBar)                   │
│                 ├── details_screens (album/artist/playlist/show)  player_screen (vertical/horizontal/queue)     │
│                 └── settings_screen (1.9k LOC), downloads_screen, importer_screen, lyrics, log_screen, updater   │
│                                                                                                                │
│  Global singletons: settings, cache, deezerAPI, downloadManager, importer, imagesDatabase                       │
│  DI: GetIt (only AudioPlayerHandler). Everything else is a top-level global.                                    │
│  Persistence: settings.json, metacache.json, homescreen.json, playback.json (app documents) + sqflite offline2 │
└───────────────┬───────────────────────────┬──────────────────────────────┬─────────────────────────────────────┘
                │ GetIt / streams           │ MethodChannel                │ MethodChannel
                ▼                           ▼                              ▼
   AudioPlayerHandler                 MainActivity (Java)            AppIconChanger (change_icon)
   (audio_service, own isolate)       - channels: r.r.refreezer/     - activity-alias switching
   - just_audio, queue, EQ,               native, .../downloads
     LastFM, Android Auto            - Messenger ↔ DownloadService
                │                    - StreamServer lifecycle
                │                           │
                ▼                           ▼
      http://localhost:36958        DownloadService (separate :ReFreezerDownloadService process)
      (NanoHTTPD StreamServer)      - downloads, decrypts (AES/Blowfish), tags files, notifications
      - streams offline files       - SQLite `downloads`, MESSENGER protocol, START_STICKY
      - proxies/decrypts Deezer CDN - Deezer.java (ARL auth, CDN resolve, crypto, tagging)
```

**Observations**

* **Two navigation systems** (root `Navigator` + `custom_navigator` per tab) and two global navigator keys. Back handling is implemented manually in `PopScope` (`main.dart:120-134`) and tries to unwind the custom stack first.
* **Three persistence mechanisms**: JSON files in the app documents directory (settings/cache/home/queue), sqflite (`offline2.db`), and a Java SQLite DB (`downloads`). No schema versions for the JSON files; no migrations for the SQLite DBs (`DownloadsDatabase.onUpgrade` calls `onCreate`, which would throw "table already exists").
* **Business logic lives in widgets.** `library.dart` (1.4k LOC) contains sorting, pagination, offline fallback and cache syncing; `settings_screen.dart` (1.9k LOC) contains 20+ widgets and platform calls; `menu.dart` performs API mutations directly.
* **The download path bypasses Dart entirely** for the actual work: Dart enqueues and observes, Java downloads. The two sides share a JSON blob of settings and a `Messenger` protocol with integer opcodes — an implicit, undocumented contract.
* **The audio stream URL is a local HTTP URL** carrying Deezer playback details in query parameters, consumed by ExoPlayer. This is the seam where the app's crypto, playback and offline features meet — and it has no authentication.

---

## 3. Features and user journeys

Full inventory (with per-feature status) in `FEATURES_INVENTORY.md`. The five journeys that matter:

### 3.1 First run / login
`LoginMainWrapper` → token ARL from settings → `deezerAPI.authorize()` → if `arl == null`, `LoginWidget` offers **email login** (md5-hashed password against `connect.deezer.com/oauth/user_auth.php`), **browser login** (in-app WebView, scrapes `arl` from a redirect), or **raw ARL paste**. On success the app home-preloads the Deezer homepage and switches to `MainScreen`.
*Friction:* the three paths are visually equal-weight outlined buttons, no explanation of what an ARL is, no "where do I find it", country-availability dialog is a blocking modal on first launch, and `settings.offlineMode` is force-set to `true` until authorisation completes (`main.dart:150`).

### 3.2 Browse → play
Home rows/grids (`HomePageScreen`) → tiles → details screens → `TrackTile` tap → `playFromTrackList` → queue build (resolving each item to a local stream URL) → playback.
*Friction:* Details screens show a full-screen spinner with no skeleton, and `AlbumDetails` sets `_error` on API failure but `_loading=false` afterwards regardless; a partially loaded album renders with "0" tracks. Queue building is O(n) network/settings work before the first sound (`_itemsToSources` resolves every URL eagerly, `audio_service.dart:520-535`) — a 1000-track playlist means 1000 resolutions before playback starts.

### 3.3 Search
Query → suggestions (debounced 300 ms) → `SearchResultsScreen` shows top 3 tracks/albums plus a horizontal artist row and "show all" links.
*Friction:* the results screen re-runs `_search()` on every rebuild because the future is created in `build()` (`search.dart:523`); errors are unreachable (spinner forever); "show all tracks" is a plain ListTile below 3 rows.

### 3.4 Download
Album/playlist/track menu → permission gate → `DownloadManager.addOffline*` → local `Download` rows → Java service downloads/tags → progress via EventChannel → notifications.
*Friction:* permission is requested per action with a customs dialog; there is no pre-flight storage-space check; failure surfacing is a toast + a coloured dot in the downloads list; "external" vs "offline" downloads are a user-visible concept that is never explained.

### 3.5 Offline use
Connectivity is sampled at screen load (`LibraryTracks._load`, `SearchScreen.initState`), falling back to sqflite-backed offline queries; playback of downloaded tracks is served by the local stream server.
*Friction:* offline detection is a snapshot, not a subscription; offline state is not shown globally; a failed stream just logs and stops with no user-visible reason (except one toast for Flow).

### 3.6 Settings
11 top-level groups (General, Downloads, Appearance, Quality, Deezer, Language, Updates, About). Quality has 4 independent pickers (mobile/wifi/offline/download) each opening a bottom sheet; Downloads has ~20 toggles and a filename-template dialog; Appearance has theme/font/icon/colour/gradient/blur/visualizer/display-mode.
*Friction:* no search inside settings; no "reset to defaults"; changes persist immediately (no Apply/Cancel); some options are labelled "might be buggy" (`settings_screen.dart:337`) or non-functional (§4).

---

## 4. Critical problems

Severity: **P0** = data loss / security / app-breaking; **P1** = blocks core flow or crashes; **P2** = degraded reliability/UX; **P3** = polish. Full evidence and fixes in `BUGS_AND_TECHNICAL_DEBT.md`.

| # | Sev | Problem | Evidence |
|---|---|---|---|
| 1 | **P0** | Local stream server (127.0.0.1:36958) serves any offline track by bare numeric ID, unauthenticated, with `usesCleartextTraffic=true` | `StreamServer.java:36-48`, `StreamServer.java:118-130`, `AndroidManifest.xml:48` |
| 2 | **P0** | ARL token (full account access) stored in plaintext `settings.json` in app documents; Spotify client secret and Last.fm hash stored alongside | `settings.dart:38`, `settings.dart:148-153`, `settings.dart:551` |
| 3 | **P1** | Corrupted/unsupported `settings.json` or `metacache.json` aborts startup with an uncaught exception → permanent white screen (only recovery: clear app data) | `main.dart:48-52`, `cache.dart:104-117`, no try/catch |
| 4 | **P1** | Search error state unreachable → infinite spinner on any API/network error | `search.dart:523-531` |
| 5 | **P1** | Unassigned `late` locals on failed requests → `LateInitializationError` crash (search suggestions, library "load all") | `search.dart:121-131`, `library.dart:393-404` |
| 6 | **P1** | Zero tests; no CI; `pubspec.lock` git-ignored; 5 uninitialised submodules; `.env`/`env.g.dart` missing → repository cannot be built or verified from a fresh clone | `.gitignore`, `.gitmodules`, `lib/utils/env.dart` |
| 7 | **P1** | No HTTP timeouts anywhere in the Dart API layer — a hung request leaves permanent spinners and a stuck download queue | `deezer.dart` (`http.get/post`), only `audio_service.dart:431` has a timeout |
| 8 | **P1** | Stream server port is fixed; if 36958 is taken, the server silently fails → *all* playback and offline playback break with no message | `StreamServer.java:40-48` (`printStackTrace`) |
| 9 | **P2** | "Visualizer" setting ships with a no-op implementation (commented out) → renders nothing; also divides by `data.length` | `audio_service.dart:947-963`, `lyrics.dart:143-160` |
| 10 | **P2** | PlayerBar rebuilds every 250 ms forever and allocates an undisposed `FocusNode` per rebuild | `player_bar.dart:34`, `player_bar.dart:58` |
| 11 | **P2** | Lyrics screen starts a **new** `Timer.periodic(350ms)` on every lyrics update; only the last is cancelled → duplicate timers, battery drain, jittery scrolling | `lyrics.dart:49-60`, `lyrics.dart:94-113` |
| 12 | **P2** | Tracks rendered with `ListView(children: List.generate(...))`; album/artist lists use `shrinkWrap` builders inside the parent list; every `TrackTile` holds a global `mediaItem` subscription plus an offline DB check → jank and memory pressure on large libraries | `library.dart:545-580`, `library.dart:829-856`, `tiles.dart:33-56` |
| 13 | **P2** | Navigation is `Navigator.push` scattered across ~40 call sites with two navigators; no route table, no deep-link→tab mapping, no back-stack invariants | `main.dart:400-470`, all screen files |
| 14 | **P2** | Android `POST_NOTIFICATIONS` permission is commented out of the manifest while startup requests it before any UI exists; download/update notifications silently fail on Android 13+ **if** no plugin merges it | `AndroidManifest.xml:19`, `main.dart:41-45` |
| 15 | **P2** | `DownloadsDatabase.onUpgrade` calls `onCreate` without dropping tables → any future schema bump crashes the download service | `DownloadsDatabase.java:40-45` |
| 16 | **P2** | Self-update downloads an APK from GitHub to external storage, opens it, with no signature/hash verification | `updater.dart:82-110` |
| 17 | **P3** | i18n drift: 11 referenced strings missing from `en_us`, 2 locales <8 % translated, stale keys duplicated | scripted check, §11 |
| 18 | **P2** | "Delete download" removes only the DB row, never the file; offline state tracked in two independent databases | `DownloadService.java:769-829`, `download.dart:498-526`, `downloads_screen.dart:262-283` |
| 19 | **P3** | Dead code/deps: `utils/blowfish.dart` (1170 LOC) unused, 5 unused routes, `math_utils.dart`, unused deps `animations`, `encrypt`, `pointycastle`, dead `proxyAddress` setting | §11 |

---

## 5. UX / UI weaknesses

Visual identity is deliberate and pleasant (MabryPro, dark-first, Deezer-ish "now playing" bar, album art colour extraction). The weaknesses are systematic rather than cosmetic.

### 5.1 Design system is implicit
* ~90 literal `fontSize:` values, 31 hard-coded `Color(0x…)`, 66 raw `Colors.*`, 108 `Container(height: …)` spacer widgets instead of a spacing scale or `SizedBox`.
* `ThemeData` is hand-built in four nearly identical 90-line blocks (`settings.dart:227-490`), so any new component must be styled four times; `ThemeData(useMaterial3: false)` opts the whole app out of Material 3.
* Global text styles are re-declared per screen ("section header" is `20px/w900` in home, `20px/bold` in search, `24px/bold` in downloads).

### 5.2 Loading / empty / error states are inconsistent
* Three different loading idioms: full-screen `CircularProgressIndicator` (details), inline row (lyrics, library, downloads), and **nothing at all** (empty queue, empty download history, empty library). A load *failure* in library albums/artists/playlists only logs and then renders an empty list, indistinguishable from "you have no albums".
* Empty states: only search has one ("No results!"). Empty library, empty downloads (blank screen with only a 2 px spacer), empty queue, and empty search history show nothing or a bare heading.
* Error states: `ErrorScreen` is used in 9 files but is a static centred icon + generic text with **no retry action**; several screens instead `print()` in debug and render stale/empty data.
* No skeletons, no shimmer, no pull-to-refresh anywhere; no offline banner.

### 5.3 Feedback and destructive actions
* Success/failure is mostly `fluttertoast` (40 call sites) — ephemeral, easily missed, unlocalised in places, and inconsistent with the dialogs used elsewhere.
* "Clear all" in Downloads deletes *every* download record (including finished history and queue) with **no confirmation** (`downloads_screen.dart:96-106`), while deleting a *single* download does confirm.
* "Delete download" removes the record but **not the file** (`DownloadService.java:769-829`) — the opposite of what the dialog promises, and storage is never reclaimed.
* Logout confirms, but the app then performs a full `Restartable.restart()` — an abrupt visual reset with no explanation.
* Long-press is the only way to reach item menus and is undiscoverable; there is no overflow affordance on tiles.

### 5.4 Interaction and accessibility
* No global "now playing" entry point other than the bottom bar; queue, lyrics, EQ and sleep timer are hidden inside the player or the player's overflow menu.
* Discoverability of primary actions in details screens is poor: "Library", "Make offline", "Download" are three equal text buttons in a row whose labels are not verbs of equal weight ("Library" toggles a favourite).
* Accessibility: most icon buttons have `semanticLabel` (good), but explicit-content 'E' badge, offline dot, and download status icons are unlabelled; text contrast depends on user-chosen primary colour with no contrast guard; no `textScaleFactor` testing; TV focus is hand-rolled (`main.dart:340-390`).
* Settings are one long flat list of 11 items leading to four very long pages (~1.9k LOC total), with no grouping headers, search, or reset.

### 5.5 Responsiveness
* Only the player screen uses `flutter_screenutil`, and it calls `ScreenUtil.init(context, …)` inside `build` (`player_screen.dart:177`) instead of `ScreenUtilInit` — everything else uses raw `MediaQuery` or fixed sizes.
* Tablet/landscape is handled case-by-case (`Row` in player, horizontal artist rows elsewhere); library/detail layouts are single-column at any width.
* Bottom `NavigationBar` + player bar + safe area is a fixed-height stack that does not adapt to gesture insets consistently.

### 5.6 Copy and localisation quality
* Mixed voice: "Fuck the Bearer Token…" in a code comment is harmless, but user copy includes jargon ("ARL", "external downloads", "smart track list", "Flow"), inconsistent capitalisation, and 11 strings absent from the translation table.
* Language picker lists locales as `de-DE`, `fr-FR` and "Baguette"/"Furry" instead of native names; changing language requires an app restart for some surfaces and not others.

---

## 6. Performance concerns

| Area | Observation | Impact |
|---|---|---|
| Queue construction | `_itemsToSources` awaits a URL resolution for **every** track in the queue before playback (`audio_service.dart:520-535`); each resolution does a file-exists check + connectivity check + JSON decode | Multi-second delay before first sound on large playlists; all-or-nothing (one failure → `null` source silently dropped) |
| Player bar | `Stream.periodic(250 ms)` rebuilds the bar (and creates a `FocusNode`) even when idle; `_progress` re-resolves the handler through `GetIt` several times per rebuild | 4 rebuilds/s forever, GC churn, focus loss on TV |
| Lists | Non-builder `ListView` with `List.generate` for full libraries, plus per-tile stream subscription and per-tile `checkOffline` platform/DB call (`tiles.dart:36-56`) | Jank while scrolling, memory growth, 1000+ subscriptions for a large favourites list |
| Download screen | Renders the entire finished-download history in a `Column` (`downloads_screen.dart:180-198`) | Slow first frame with long history |
| Images | `CachedNetworkImage` without `memCacheWidth`/`maxWidth`; `PaletteGenerator` decodes the full-size image on the UI isolate for colour extraction (`cached_image.dart:20-30`, `player_screen.dart:70-80`) | Frame drops on every track change with gradient/blur background on |
| Startup | `prepareRun` awaits logging + settings + cache **before** `runApp`; then a second async authorise; `Permission.notification.request()` before UI | White splash and a slow cold start; a hung network call at startup is unbounded |
| Analyzer hygiene | `analysis_options.yaml` excludes generated files but there is no lint ratchet; 480 non-null assertions in `lib/ui` | Runtime null crashes are statistically likely; nothing surfaces them pre-release |
| Locale tables | `crowdin.dart` is ~600 KB of Dart map literals, compiled into the binary and parsed on first localisation lookup | APK size, startup cost |
| Build | `minifyEnabled false`, `shrinkResources false`, no ProGuard/R8 rules | Larger APK, no dead-code stripping |

---

## 7. Security concerns

1. **Unauthenticated loopback streaming (P0).** Any app or browser on the device can `GET http://127.0.0.1:36958/?id=<trackId>` and receive the decrypted audio of the user's offline library. There is no token, no origin check, no per-session secret. (`StreamServer.java:118-175`.)
2. **Credential storage (P0).** `arl` is a long-lived session credential equivalent to the account password. It is persisted verbatim in `settings.json` (`settings.dart:38`, `getPath()` → app documents). Spotify `clientSecret`/`accessToken`/`refreshToken` and the Last.fm password hash are in the same file. No `flutter_secure_storage`, no Keystore/EncryptedSharedPreferences.
3. **Cleartext traffic enabled globally** (`usesCleartextTraffic="true"`), not scoped to `localhost` via a network security config. This weakens an otherwise HTTPS-only app and permits accidental cleartext to any host.
4. **Playback tokens in query strings** (`trackToken`, `md5origin`, `mv` in the local URL) — they end up in ExoPlayer logs and any crash/log capture. Low direct risk (loopback) but poor hygiene.
5. **No certificate validation beyond platform defaults**, and three different hard-coded `User-Agent` strings impersonating browsers — expected for this class of client, but undocumented and fragile.
6. **Self-updater without integrity verification** (`updater.dart:82-120`): downloads an APK and hands it to the system installer; `REQUEST_INSTALL_PACKAGES` is declared. A compromised GitHub release or MITM without HTTPS enforcement would install arbitrary code. At minimum: verify `sha256` against the release asset, enforce `https`, and prefer an F-Droid/Play distribution.
7. **Broad storage permission** — `MANAGE_EXTERNAL_STORAGE` plus `requestLegacyExternalStorage`, and a permissions flow that escalates to "All files access" for saving to Music. Scoped storage (`SAF`/MediaStore) would be safer and Play-compliant.
8. **In-app browser login** loads `deezer.com` and executes JS to force a redirect; if Deezer changes flow, the app silently stores no ARL. Low risk, but the WebView has default settings (no `javaScriptCanOpenWindowsAutomatically` restrictions, no URL allowlist beyond the parsed redirect).
9. **Email/password login** sends an md5 of the password to a Deezer OAuth endpoint over HTTPS with a browser UA and spoofed client IP headers (`deezer_login.dart:14-17`, `:49-58`). Functionally it may still work, but it is an unsupported flow; storing the resulting ARL is the actual risk (see #2).
10. **Logs contain identifiers**: `refreezer.log` (external storage) records track IDs, errors and stack traces; `download.log` is user-readable. No token logging observed, but the log file is world-readable on pre-scoped-storage devices.

Out of scope for "fix" in this engagement, but must be stated plainly: the app uses Deezer's internal APIs and redistributes decrypted audio — legal risk is the operator's, not a code defect. Nothing in this repository should be described as "production release to Play Store" without the policy work listed in `UPGRADE_ROADMAP.md` §M8.

---

## 8. Recommended architecture improvements

Pragmatic, incremental. No rewrite, no new heavyweight framework. Rationale and trade-offs in `ARCHITECTURE.md` §8 and `UPGRADE_ROADMAP.md` (decision log).

1. **Introduce a repository/service seam** for reads that screens use today: `DeezerRepository` (search/album/artist/playlist/home), `LibraryRepository`, `DownloadRepository`. Start by *moving* existing calls behind interfaces; do not change behaviour. This makes screens testable and gives one place for error mapping.
2. **Replace ad-hoc loading/error handling with one pattern**: a small sealed `Result`/`AsyncValue`-style type plus reusable `AsyncView` widget (loading / empty / error+retry). Kill `FutureBuilder(future: ...)` in `build` in favour of a single `load()` triggered by `initState`/`didUpdateWidget`.
3. **Routing**: define a minimal route table (`onGenerateRoute`) with typed route objects, keep `custom_navigator` (it is load-bearing for TV focus), and map deep links to `(tab, route)` explicitly instead of pushing on the root navigator.
4. **State**: keep `setState` for local UI state, but move the five hot cross-screen concerns into `ChangeNotifier`/`ValueNotifier` providers: playback summary, library (favourites/albums/artists/playlists), downloads, connectivity/offline mode, settings. This is the smallest change that removes the "return to Library re-fetches everything" problem and the global-mutable-singleton footguns.
5. **Error taxonomy + logging**: one `AppError` mapper (network/timeout/auth-expired/deezer-error/storage) → user-facing message + retry affordance; add HTTP timeouts (10–20 s) and bounded retries with backoff in one `ApiClient`.
6. **Persistence**: version the JSON files (`schemaVersion`), wrap load/save in try/catch with atomic write + backup, and move credentials to Keystore-backed secure storage with a one-time migration.
7. **Design system**: a `theme/` module with colour/spacing/typography tokens, one `ThemeData` factory parameterised by a `ThemeTokens` object (replacing the four 90-line copies), and shared components (`SectionHeader`, `AsyncView`, `EmptyState`, `AppIconButton`, `SheetAction`).
8. **Stream server hardening**: bind to loopback (already), require a per-launch random token in the path/query, use an ephemeral port returned via MethodChannel, and add a `network_security_config.xml` scoped to `127.0.0.1`.
9. **Testing harness first, then refactor**: add `test/` with unit tests for pure logic (`definitions` parsing, `Version`, filename templating, sorting, cache serialisation) and widget tests for `AsyncView`/settings rows. This is what turns every later change from "hope" into "verified".
10. **Build reproducibility**: commit `pubspec.lock`, replace uninitialised submodules with pinned pub/git dependencies where possible, commit `.env.example` (not `.env`), and generate `env.g.dart` in CI. Add a GitHub Actions workflow (`analyze` + `test` + `build apk`) as the gate.

---

## 9. Prioritised implementation roadmap (summary)

Full milestones, acceptance criteria and file lists in `UPGRADE_ROADMAP.md`.

| Phase | Milestone | Why first |
|---|---|---|
| 0 | **M0 — Verification harness**: pin lockfile, restore build, add CI (analyze/test/build), `.env.example`, submodule or dependency strategy | Nothing can be trusted or measured until the project builds reproducibly |
| 1 | **M1 — Crash & data-integrity containment**: corrupt-state recovery, `late` crashes, unreachable error branches, HTTP timeouts, `mounted` discipline, `DownloadsDatabase` migration safety | Cheap, surgical, removes the worst user-visible failures |
| 2 | **M2 — Security hardening**: loopback auth token + dynamic port, secure credential storage + migration, scoped cleartext policy, update integrity check | Highest severity, low UI risk, contained blast radius |
| 3 | **M3 — UX foundation**: design tokens + shared components, `AsyncView` (loading/empty/error/retry), navigation & tab behaviour, empty states, destructive-action confirmations | Unlocks every subsequent screen change and fixes consistency complaints |
| 4 | **M4 — Core-flow polish**: Home, Search (+ real error state, results paging), Library (builder lists, sorting correctness, filters), Details, Player/queue, Lyrics timer bug, Settings IA (search/grouping/reset) | The screens users spend 95 % of their time in |
| 5 | **M5 — Performance**: lazy queue resolution + prefetch window, player bar tick only while playing, image sizing/cache policy, per-tile state removal, list virtualisation | Do after M4 so measurements reflect final UI |
| 6 | **M6 — Architecture seam**: repositories, connectivity/offline provider, persistence versioning, dead-code removal, dependency pruning | Do after tests exist (M0) and UX is stable, to avoid churn |
| 7 | **M7 — Accessibility/localisation quality**: semantic labels, contrast guard, text scaling, i18n gap fixes, two under-translated locales | Cross-cutting; needs the design system from M3 |
| 8 | **M8 — Release readiness**: versioning/build numbers, signing docs, R8 + icon/splash assessment, README/technical docs, store-policy assessment | Last, because it certifies the rest |

---

## 10. Estimated complexity and risks

| Workstream | Complexity | Est. effort* | Main risk | Mitigation |
|---|---|---|---|---|
| M0 build/CI restoration | Low–Medium | 1–2 d | Submodules are external forks; `disk_space_plus` git dep; no lockfile | Prefer pinned versions; keep submodules but pin SHAs; document exact toolchain |
| M1 crash containment | Low | 2–3 d | Touches many screens; regressions in error paths | Pure-Dart changes + tests; incremental per-file commits |
| M2 security | Medium | 2–3 d | Credential migration can log users out; dynamic port must reach ExoPlayer & Java service | Migration with fallback to re-login; token injected in URL path; test both process boundaries |
| M3 design system/UX foundation | Medium–High | 5–7 d | Touching 20 screens risks visual regressions and TV focus breakage | Tokens first (no behaviour change), then per-screen; screenshot review; keep focus nodes |
| M4 core-flow polish | High | 7–10 d | Library/search logic is entangled with UI; pagination + offline fallback | Extract logic into repositories as part of the work; add tests per flow |
| M5 performance | Medium | 3–4 d | Queue laziness can break just_audio sequencing/gapless behaviour | Feature-flag, measure before/after on a 1000-track playlist |
| M6 architecture seam | High | 5–8 d | Broad refactor with no user-visible payoff; temptation to over-abstract | Do only what M1–M5 proved necessary; no framework adoption |
| M7 accessibility/i18n | Medium | 2–3 d | Contrast vs user-chosen accent colour; translation completeness | Contrast guard + fallback; batch translation review |
| M8 release readiness | Medium | 2–4 d | Play policy blockers (MANAGE_EXTERNAL_STORAGE, self-update), signing | Distribute via GitHub/F-Droid, document; ask before store work |

\* Rough engineer-days for one experienced Flutter dev, excluding translation turnaround and device-matrix QA.

**Top project risks**

1. **Legal/product risk dominates technical risk.** The app depends on private Deezer APIs and decrypts content; any "production polish" must not be mistaken for a green light to publish commercially. Explicitly out of scope unless the user asks.
2. **No runtime verification available in this environment** (no SDK, no pub.dev). Every behavioural claim must be re-validated on a device — hence M0 first.
3. **Two-process boundary** (Dart ↔ Java download service) means some fixes (stream auth, port) require coordinated changes and a real device to test.
4. **Feature density** (~60 settings, 6 media types, TV/Auto) means "polish" is breadth-heavy; must be milestone-gated to avoid a sprawling, unverifiable change set.
5. **Global mutable state** makes bugs non-local; expect "fix one screen, break another" until the M6 seam exists. Mitigate by adding tests before moving logic.

---

## 11. Audit method, scripted checks and results

Because no Dart toolchain was available, verification relied on (a) full manual reading of all 40 hand-written Dart files and 13 Java files, (b) scripted static checks, (c) cross-checking generated code against models.

Scripted checks executed (Python over the working tree):

| Check | Result |
|---|---|
| Files/LOC | 227 tracked files; `lib/` 31,667 lines Dart (11,176 of which are `crowdin.dart` translations → ~20.5k real Dart), `android/` 3,139 lines Java |
| Declared deps vs `package:` imports | 59 runtime deps; **unused**: `animations`, `encrypt`, `pointycastle` |
| Declared assets vs disk | 0 missing |
| Asset references in code not declared in pubspec | 6 (`assets/cover.jpg`, `cover_thumb.jpg`, `icon.png`, `icon_legacy.png`, `browse_icon.png`, `favorites_thumb.jpg`) — still bundled because each is listed, reported only to show the manifest is hand-maintained and drift-prone |
| `.i18n` literal keys missing from `en_us` | **11** (`App icon`, `Apply`, `Download externally`, `External Storage Access Required`, `Mix based on`, `Playlist menu`, `Select app icon`, `Select country`, `Storage Permission Required`, + 2 long permission strings that differ textually from the translated originals) |
| Locale coverage vs `en-US` keys (357) | 31 locales; median 99.4 %; **`ur-PK` 3.9 % (14 keys), `te-IN` 7.8 % (28 keys)**; `ko-KR` 71 %, `fil-PH` 73 %, `ast-ES` 82 % |
| Generated JSON code vs models | `cache.g.dart`, `settings.g.dart`, `definitions.g.dart` present and consistent with current fields (no drift detected) |
| `test/` directory | **absent**; 0 test files |
| CI workflows | **absent** (only issue templates under `.github/`) |
| `pubspec.lock` | git-ignored, not committed |
| Submodules | 5 declared (`custom_navigator`, `equalizer_flutter`, `external_path`, `move_to_background`, `scrobblenaut`), all empty in this checkout |
| Build-time secrets | `lib/.env` and `lib/utils/env.g.dart` git-ignored and absent → compile blocker without generation + credentials |
| Dead code | `lib/utils/blowfish.dart` (1,170 LOC, never imported), `lib/utils/math_utils.dart`, 5 of 7 routes in `ui/router.dart`, `QueueState.empty`, `Settings.proxyAddress` (UI commented out) |

**Not executed / BLOCKED:** `flutter pub get`, `dart format`, `flutter analyze`, `dart run build_runner`, `flutter test`, `flutter build apk`, any emulator run, any API interaction. See `DEVELOPMENT_STATUS.md` for the exact blocker and what is required to clear it.

---

## 12. Deliverables produced in Phase One

| Document | Contents |
|---|---|
| `PROJECT_AUDIT.md` | This report: purpose, architecture, journeys, problems, UX, performance, security, recommendations, roadmap, risk |
| `ARCHITECTURE.md` | Module map, runtime topology, data flows, layering assessment, target architecture, ADR-lite decisions |
| `FEATURES_INVENTORY.md` | Per-feature and per-screen status table, settings inventory, journey maps, verification status |
| `BUGS_AND_TECHNICAL_DEBT.md` | Prioritised bug register with evidence, impact, fix and verification plan; debt register |
| `UPGRADE_ROADMAP.md` | M0–M8 milestones with objectives, affected files, acceptance criteria, risks, approvals needed |
| `DEVELOPMENT_STATUS.md` | Phase status, completed work, blockers, tests executed, files modified, decisions |
| `CHANGELOG.md` | Baseline entry (documentation-only change) |

No application code, assets or Android configuration were modified in Phase One.
