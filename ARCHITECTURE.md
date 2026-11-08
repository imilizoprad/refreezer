# ReFreezer — Architecture

**Status:** as-is architecture documented at commit `2bb8009`, plus a proposed target architecture.
**Audit:** Phase One (2026-11-08). No production code changed.

---

## 1. System overview

ReFreezer is a single-module Flutter Android app with three runtime execution contexts and one local network interface:

| Context | Technology | Responsibility |
|---|---|---|
| **Flutter UI isolate** | Dart/Flutter, `main.dart` | Rendering, navigation, API calls (search/browse/library), settings/cache persistence, queue control, downloads orchestration |
| **Audio service isolate** | `audio_service` + `just_audio` (`service/audio_service.dart`) | Media session, queue, ExoPlayer control, equalizer bridge, Last.fm scrobbling, Android Auto browsing |
| **Java app process** | `MainActivity`, `StreamServer`, `Deezer`, `DeezerDecryptor`, `ChangeIconPlugin`, `DownloadsDatabase` | Method/Event channels, local streaming server, Deezer CDN resolution + decryption, launcher-icon switching |
| **Java download service process** (`:ReFreezerDownloadService`) | `DownloadService`, `Download`, `DownloadLog` | Background multi-threaded downloads, tagging, notifications, its own SQLite DB, `START_STICKY` |
| **Local HTTP endpoint** | NanoHTTPD on `127.0.0.1:36958` | Serves decrypted/offline audio to ExoPlayer via `http://localhost:36958/?...` |

Externally, it talks to Deezer (`www.deezer.com/ajax/gw-light.php`, `api.deezer.com`, `auth.deezer.com`, `pipe.deezer.com`, CDN hosts), GitHub (update check), Last.fm (scrobbling), Spotify (import: OAuth + embed-page scraping) and Crowdin-sourced translations (offline, generated).

---

## 2. Runtime topology

```
                          ┌──────────────────────────── Android device ────────────────────────────┐
  ┌─────────────┐         │  ┌─────────────────────── MainActivity (:default) ──────────────────┐   │
  │ Deezer web  │◀──HTTPS─┼──┤ MethodChannel 'r.r.refreezer/native'  MethodChannel 'change_icon'│   │
  │ Deezer API  │         │  │ EventChannel 'r.r.refreezer/downloads'                            │   │
  │ Deezer CDN  │         │  │ Messenger (state/progress/commands) ⇄ DownloadService             │   │
  │ GitHub API  │         │  │ owns StreamServer (NanoHTTPD, 127.0.0.1:36958)                     │   │
  │ LastFM      │         │  └───────────────┬───────────────────────────────┬───────────────────┘   │
  │ Spotify     │         │                  │                               │                       │
  └─────────────┘         │        ┌─────────▼─────────┐            ┌────────▼────────────────┐     │
                          │        │  Flutter UI       │            │ :ReFreezerDownloadService│     │
                          │        │  (Dart isolate)   │            │  DownloadService (Java)  │     │
                          │        │                   │            │  SQLite 'downloads'      │     │
                          │        │  ┌─────────────┐  │            │  jaudiotagger tagging    │     │
                          │        │  │AudioHandler │  │            └────────┬────────────────┘     │
                          │        │  │(audio_serv.)│  │                     │                      │
                          │        │  └──────┬──────┘  │                     │ writes files         │
                          │        │         │          │                     ▼                      │
                          │        └─────────┼──────────┘            /storage/emulated/0/Music/...   │
                          │                  │ ExoPlayer                    app-external-files/offline │
                          │                  ▼                                                         │
                          │        http://127.0.0.1:36958  ◀── StreamServer ── reads offline files   │
                          └────────────────────────────────────────────────────────────────────────────┘
```

### Process/thread notes

* `DownloadService` runs in a **separate process** (`android:process=":ReFreezerDownloadService"`, `stopWithTask="false"`) — this is why settings are shipped to it as a JSON blob and why download state lives in a second database.
* `AudioPlayerHandler` extends `BaseAudioHandler` and is registered via `GetIt` inside the UI isolate; the `audio_service` plugin hosts it (in this configuration it runs in the same UI isolate process, driven by the media session).
* `StreamServer` is created by `MainActivity` when Dart calls `startServer` (`MainActivity.java:193-217`), and its `streams` map is queried by the UI for quality/format info (`StreamQualityInfo`).

---

## 3. Module map (Dart)

| Path | LOC* | Role | Notes / coupling |
|---|---:|---|---|
| `main.dart` | 494 | App shell, theme plumbing, login gate, tab scaffold, lifecycle, deep links, quick actions, preload, key handling (TV) | Owns globals `updateTheme`, `logOut`; creates `Cache`/`Settings` before `runApp` |
| `settings.dart` | 577 | Settings model + JSON + 4 `ThemeData` variants + quality mapping + app-icon switching | Imports `api/download.dart`, `service/audio_service.dart`, `ui/cached_image.dart`, `main.dart` → **cyclic** with `main.dart` |
| `api/deezer.dart` | 600 | Deezer private/public/pipe API: auth, search, album, artist, playlist, home, flow, lyrics, playlist mutations, smart radio, shuffle | Static-ish global `deezerAPI`; no error mapping, no timeouts |
| `api/definitions.dart` | 1,281 | ~25 models (`Track`, `Album`, `Artist`, `Playlist`, `Lyrics*`, `HomePage*`, `Show*`, `Sorting`, `QueueSource`), `toMediaItem`/`fromMediaItem`, SQL mapping, home-page cache load/save | Model layer doubles as file-cache layer (`HomePage.load/save`) |
| `api/cache.dart` | 166 | `Cache` (favourites IDs, history, sort order, search history, update timestamp) | JSON file, no schema version |
| `api/download.dart` | 816 | `DownloadManager`: channel ops, offline SQLite (`offline2.db`), offline queries, path templating, permissions/dialogs | Mixes persistence + UI dialogs + platform IO |
| `api/deezer_login.dart` | 90 | Email/password → ARL via `connect.deezer.com` + cookie juggling | Uses `Env` secrets; custom exception |
| `api/importer.dart` | 173 | Spotify→Deezer playlist import (ISRC/UPC matching, playlist creation, progress stream) | Global singleton; state machine with mutable fields |
| `api/spotify.dart` | 230 | Spotify OAuth (local `HttpServer` on :42069), embed-page scraper, credential persistence | Writes credentials into `Settings` |
| `service/audio_service.dart` | 994 | `AudioPlayerHandler`: queue, media items, stream URLs, quality, EQ, saved queue, scrobbling, Android Auto bridging, `QueueState` | ~1k LOC god-object; calls `downloadManager`/`deezerAPI` directly |
| `service/service_locator.dart` | 12 | Registers `AudioPlayerHandler` in GetIt | Only DI in the app |
| `ui/home_screen.dart` | 388 | AppBar, home page sections (row/grid), channel drill-down, item routing | Loads local cache then API |
| `ui/search.dart` | 1,018 | Search field, suggestions, history, browse cards, results screen, list screens for tracks/albums/playlists/shows/episodes, deep-link entry `openScreenByURL` | Global function used by `main.dart` |
| `ui/library.dart` | 1,373 | Library hub + tracks/albums/artists/playlists/history screens with sorting, paging, offline fallback | 30 `setState`; contains business logic |
| `ui/details_screens.dart` | 1,288 | Album, artist, discography, playlist, show details + "make offline" widgets | 30 `setState`; inline API mutations |
| `ui/player_screen.dart` | 1,200 | Player (vertical/horizontal), queue screen, seek bar, quality info, repeat/shuffle, big art, colour extraction | Global `updateColor`, `scaffoldBackgroundColor` |
| `ui/player_bar.dart` | 270 | Mini player + play/pause + progress | 250 ms periodic rebuild |
| `ui/settings_screen.dart` | 1,956 | Settings hub + 10 sub-screens + dialogs (icon, font, quality, country, filename template, tags, directory picker, storage info, credits, Last.fm) | Largest file; UI + platform/permission logic |
| `ui/menu.dart` | 857 | Bottom-sheet action menus for all entity types, sleep timer, playlist dialogs, downloads | Executes API mutations + downloads directly |
| `ui/downloads_screen.dart` | 366 | Download list grouped by state, log viewer | Non-virtualised lists |
| `ui/lyrics.dart` | 236 | Synced/unsynced lyrics, auto-scroll, tap-to-seek, (dead) visualizer | Timer leak |
| `ui/importer_screen.dart` | 710 | Spotify importer V1/V2 flows, settings, status | 14 `setState` |
| `ui/android_auto.dart` | 266 | Media-browser tree for Android Auto (`getChildren`, `playFromMediaId` via `_aa_` prefix) | Direct API calls inside browse callbacks |
| `ui/updater.dart` | 383 | GitHub release check, APK download/install, notification | No integrity check |
| `ui/cached_image.dart` | 167 | Image widget + palette helpers + zoomable art | `colors.first` unsafe |
| `ui/tiles.dart` | 668 | All tile/card widgets (track, album, artist, playlist, channel, show, episode) | Per-tile stream subscription |
| `ui/elements.dart` | 85 | `FreezerAppBar`, `LeadingIcon`, divider, popup style | AppBar re-declares a `Theme` on every use |
| `ui/router.dart` | 202 | 7 custom page transitions + circular reveal clipper | 5 unused |
| `ui/error.dart` | 62 | `ErrorScreen` (no retry) | Global `counter` heuristic for ARL-expired hint |
| `ui/log_screen.dart`, `ui/restartable.dart` | 62/37 | In-app log viewer; app-restart wrapper | |
| `utils/*` | ~1,700 | Logging, file/permission utils, cookie manager, env (envied), version (vendored), blowfish (**dead**), math (**dead**), icon changer, media-item JSON codec, navigator keys | |
| `languages/en_us.dart` + `crowdin.dart` | 462 + 11,176 | i18n tables and `String.i18n` extension | ~600 KB generated Dart |

\* LOC from `wc -l`, including generated `.g.dart` only where stated.

---

## 4. Navigation

* **Root navigator** (`mainNavigatorKey`, `MaterialApp.navigatorKey`): hosts dialogs, detail pushes from deep links, and the `LoginMainWrapper → MainScreen` swap.
* **Custom navigator** (`customNavigatorKey`, `custom_navigator` package): per-tab stack hosted inside `MainScreen.body`. Tapping a bottom tab pops the whole custom stack and swaps the home widget (`main.dart:430-445`).
* **Back handling**: `PopScope(canPop: false)` → if custom stack can pop, pop it; otherwise `MoveToBackground.moveTaskToBack()` (`main.dart:120-135`). This deliberately prevents process exit.
* **Transitions**: custom `PageRouteBuilder` subclasses in `ui/router.dart`; only `SlideBottomRoute` (player) and `CircularExpansionRoute` (menu-driven) are used today; everything else uses `MaterialPageRoute` inline.
* **Deep links**: `AndroidManifest` registers `deezer.com`, `deezer.page.link`, `dzr.page.link` hosts; `openScreenByURL` parses links and pushes on the **root** navigator, which means a deep-linked album opens above the tab scaffold, not inside a tab.
* **Android Auto**: separate "navigation" via media IDs prefixed `_aa_`, resolved in `AndroidAuto.getScreen` and `playFromMediaId`.

**Consequences:** no route table, no typed arguments, no single place to add analytics/guards, and every screen must remember to handle both navigators. TV focus traversal is hand-coded in `main.dart:340-400` and depends on widget tree shape (`children.last`, `parent!.parent!.children.last`).

---

## 5. State management

* **Local state:** `setState` in ~17 files (~180 call sites). No `InheritedWidget`, `Provider`, `Riverpod`, `Bloc`, `ValueNotifier` for shared data.
* **Shared state:** global mutable singletons (`settings`, `cache`, `deezerAPI`, `downloadManager`, `importer`, `imagesDatabase`) plus mutable globals (`updateTheme`, `logOut`, `updateColor`, `scaffoldBackgroundColor`, `mainNavigatorKey`, `customNavigatorKey`).
* **Reactive state:** only three streams are used consistently: `audioHandler.mediaItem`, `audioHandler.playbackState`/`queueStateStream`, and `downloadManager.serviceEvents`.
* **Cache/settings writes** are fire-and-forget (`settings.save()` unawaited in many places) and every `save()` pushes the whole settings JSON to the download service (`settings.dart:245`), so a rapid sequence of toggles floods the channel.

**Consequences:** screens cannot observe changes made elsewhere (e.g., favouriting an album in Search does not refresh Library), library screens refetch on every visit, and the "which piece of code mutated this?" question is unanswerable without a debugger.

---

## 6. Error handling

| Layer | Current behaviour |
|---|---|
| HTTP/API (`deezer.dart`) | No timeouts, no retry, no status-code checks; failures surface as `ClientException`, `FormatException`, `TypeError` (null from `data['results'][...]`) |
| Screens | Mixed: `try/catch → print(e)` in debug (data silently missing), `FutureBuilder` with unreachable `hasError` (search), `_error` flags (details, updater), `ErrorScreen` with no retry |
| Playback | `_playbackError` logs and calls `stop()`; no user-facing message; `Connection aborted` is explicitly ignored |
| Downloads | Java service logs to `download.log`, sets `DownloadState.ERROR/DEEZER_ERROR`; UI shows a coloured dot + toasts |
| Persistence | Loads are unguarded; corrupt JSON aborts startup (`main.dart:48-52`); save errors are unhandled futures |
| Global | No `FlutterError.onError`, no `PlatformDispatcher.onError`, no crash reporting, no `ErrorWidget.builder` |

**Consequence:** the app's failure mode is "silent or fatal", never "explain and retry". That single property explains most UX complaints in `PROJECT_AUDIT.md` §5.

---

## 7. Persistence and data

| Store | Location | Content | Versioning | Owner |
|---|---|---|---|---|
| `settings.json` | app documents | All settings incl. `arl`, Last.fm hash, Spotify client id/secret/tokens | none | `settings.dart` |
| `metacache.json` | app documents | Favourite track IDs, playback history (stored `Track` objects), per-list sorting, search history, update check timestamp | none | `api/cache.dart` |
| `homescreen.json` | app documents | Serialised Deezer home page (`HomePage`) | none | `api/definitions.dart` |
| `playback.json` | app documents | Queue (`MediaItem` maps), index, position, loop mode, queue source | none | `service/audio_service.dart` |
| `offline2.db` | databases dir | `Tracks`, `Albums`, `Artists`, `Playlists` for offline browsing | sqflite v1 (no migrations) | `api/download.dart` |
| `downloads` (Java) | databases dir | Download queue/history rows | `SQLiteOpenHelper` v1, `onUpgrade` broken | `DownloadsDatabase.java` |
| `offline/` files | app external files dir | Private ("offline") tracks keyed by track ID | — | `DownloadService` |
| User music dir | external storage (SAF / MANAGE_EXTERNAL_STORAGE) | Tagged audio, art, lyrics, `.nomedia` | — | `DownloadService` |
| `refreezer.log`, `download.log` | app external files dir | Diagnostics | truncated each launch / file | `utils/logging.dart`, `DownloadLog` |

Note: history stores full `Track` objects (with nested album/artists/art URLs) inside `metacache.json`; the file grows without bound and is rewritten on every history append.

---

## 8. Target architecture (proposed, incremental)

Goal: keep behaviour, add seams so that fixes are local, testable and reversible. No framework adoption.

```
lib/
  app/            app.dart, router.dart, tabs_shell.dart, lifecycle.dart, theme/
  core/           result.dart, failures.dart, logger.dart, connectivity.dart, formatters/
  data/
    api/          deezer_client.dart (timeouts, retries, error mapping), deezer_auth.dart
    models/       (moved definitions.dart, split by domain later if needed)
    repositories/ deezer_repository.dart, library_repository.dart, download_repository.dart,
                  settings_repository.dart (secure credential store), cache_repository.dart
    local/        json_store.dart (versioned, atomic, backed up), offline_db.dart
  features/
    home/ search/ library/ album/ artist/ playlist/ player/ queue/ lyrics/
    downloads/ importer/ settings/ onboarding/
      <feature>/<feature>_screen.dart, <feature>_controller.dart (ChangeNotifier), widgets/
  services/       audio/ (audio_handler.dart split), downloads/, scrobbling/, updater/
  ui/             design_system/ (tokens, async_view, empty_state, section_header, ...)
  platform/       channels (stream_server client, icon changer, download service port)
```

Key decisions (ADR-lite):

| ID | Decision | Rationale | Cost of not doing |
|---|---|---|---|
| A1 | Repository seam over existing globals, implemented by *moving* code, not rewriting | Screens become testable; one place for error mapping; enables the M1 fixes to be tested | Bugs stay non-local; every change risks regressions |
| A2 | One `Result<T, AppFailure>` type + `AsyncView` widget | Replaces three loading idioms and the unreachable-error bug class | Inconsistent states remain; new screens copy the old bugs |
| A3 | Keep `custom_navigator`; add a typed route table and tab-aware deep links | It is load-bearing for TV focus and tab stacks; replacement is high risk for no user benefit | Route strings stay implicit; deep links keep opening over the tabs |
| A4 | Keep `GetIt` but scope it to services only (`AudioPlayerHandler`, repositories) | Matches existing pattern, minimal churn | DI debate wastes time |
| A5 | `ChangeNotifier` + `ValueListenableBuilder` for shared state (no external state package) | Zero new dependencies; enough for 5 shared concerns | Adding Riverpod/Bloc is a large unverifiable refactor |
| A6 | Versioned JSON with atomic write + `.bak` recovery; credentials move to Keystore | Startup must never be bricked; tokens must not be plaintext | Data loss + account exposure |
| A7 | Stream server: ephemeral port + per-launch secret path segment, exposed to Dart via channel | Closes a P0 with a small, contained change | Local audio exfiltration remains |
| A8 | No new dependencies unless a milestone proves the need | 59 deps already; 3 unused | Further dependency debt |
| A9 | Keep the Java download service (do not port to Dart) | It is the most battle-tested part; porting risks file corruption | Weeks of risky work, no user benefit |
| A10 | Testing starts with pure logic + widget tests for shared components | Highest value per hour without a device farm | No regression safety net |

---

## 9. Coupling hot-spots (prioritised for untangling)

1. `settings.dart` ⇄ `main.dart` (theme callback) and `settings.dart` → `download.dart`/`audio_service.dart`/`cached_image.dart`. **Fix:** move theme construction into `app/theme/`, make settings a plain data object + repository; replace `updateTheme()` global with a `ValueListenable<ThemeTokens>`.
2. `audio_service.dart` → `deezerAPI` + `downloadManager` + `android_auto` + `ui/*`. **Fix:** inject a `QueueBuilder`/`StreamUrlResolver` and an `AndroidAutoTree` collaborator.
3. `library.dart` → API + cache + download DB + widgets. **Fix:** `LibraryRepository` returning `Result<List<Track>>`, screen becomes presentation only (M6), after M1 makes it safe.
4. `menu.dart` → every mutation API. **Fix:** extract action handlers; menu becomes a widget factory over callbacks.
5. `definitions.dart` (models + home cache + SQL mappers). **Fix:** split cache persistence out; keep SQL mapping with the download repository.

---

## 10. What must not change (guardrails)

* `custom_navigator` + `PopScope` back semantics (TV/remote users depend on it).
* `audio_service` + `just_audio` integration and the Java download service contract (opcodes, JSON settings blob) unless coordinated end-to-end.
* The local-stream-url playback path — until the stream server is authenticated, do not add a second path.
* Android Auto media-ID scheme (`_aa_` prefix) and the `MediaBrowserService` manifest entries.
* Deezer request shapes (`gw-light` methods and pipe GraphQL query) — changing them is a backend-contract change and requires explicit approval.
