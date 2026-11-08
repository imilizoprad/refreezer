# ReFreezer — Bugs & Technical Debt

**Baseline:** `2bb8009` / v0.7.15 · **Audit type:** static (no runtime, see `DEVELOPMENT_STATUS.md`)
**Legend:** **P0** data loss/security · **P1** blocks a core flow or crashes · **P2** degraded reliability/UX · **P3** polish/debt

Each item lists: evidence → impact → proposed fix → how it will be verified.

---

## 1. Defect register

### BUG-01 · Unauthenticated local stream server — **P0**

* **Evidence:** `android/app/src/main/java/r/r/refreezer/StreamServer.java:36-48` binds `127.0.0.1:36958`; `:118-175` `offlineStream()` serves any file in `offlinePath` whose name matches the `id` query parameter. No token/origin/session check. Manifest sets `android:usesCleartextTraffic="true"` (`AndroidManifest.xml:48`).
* **Impact:** any app — or any browser on the device — can `GET http://127.0.0.1:36958/?id=<trackId>` and exfiltrate decrypted audio of the user's offline library. Also enables enumeration if IDs are guessable.
* **Fix:** add a per-launch random secret to the path (e.g. `/s/<token>/?id=`), generate it in `MainActivity`, pass it to Dart via channel and to `QueueBuilder` for stream URLs; use an ephemeral port (`NanoHTTPD(host, 0)`) and return it via the same channel; add `android/app/src/main/res/xml/network_security_config.xml` allowing cleartext **only** for `127.0.0.1`/`localhost`; remove blanket `usesCleartextTraffic`.
* **Verify:** unit test on the URL builder; instrumented check that a request without the token returns 403; manual `curl` from a shell app on device.

### BUG-02 · Credentials stored in plaintext — **P0/P1**

* **Evidence:** `settings.dart:38` (`arl`), `:148-153` (`lastFMPassword` hash, `spotifyClientId`, `spotifyClientSecret`, `spotifyCredentials`), persisted via `getPath()` → app documents `settings.json`.
* **Impact:** ARL = full account access; readable by root/backup tools (`android:allowBackup` default true, not restricted). Spotify client secret and refresh token exposed the same way.
* **Fix:** introduce `SecureCredentialStore` using Keystore-backed storage (new dependency required — approval needed, see roadmap M2); migrate on first launch, delete plaintext fields, keep a re-login fallback; set `android:allowBackup="false"` or add `backup_rules` excluding `settings.json`.
* **Verify:** unit test for migration (old JSON → secure store → plaintext gone); inspect `adb backup` output / app files on device.

### BUG-03 · Corrupt state bricks startup — **P1**

* **Evidence:** `main.dart:48-52` → `Settings().loadSettings()` then `Cache.load()` with no error handling; `cache.dart:104-117` (`jsonDecode` + `Cache.fromJson` can throw `FormatException`/`TypeError`); `settings.dart:237-250` same pattern. `Cache._searchHistoryItemFromJson` indexes an enum by a raw int (`cache.dart:135`).
* **Impact:** a partially written or older/corrupt JSON leaves the app on a white screen at every launch. Only remedy: clear app data (loses downloads history and settings).
* **Fix:** `JsonStore<T>` helper with atomic write (temp + rename), `.bak` rotation, schema version field, `try/catch` fallback to defaults, and logging; wrap `prepareRun` so a failure still starts the UI with defaults and shows a recoverable banner; validate enum indices.
* **Verify:** unit tests feeding truncated/renamed/typed-wrong JSON; manual: corrupt files on device, confirm app starts with defaults.

### BUG-04 · Search results can never show an error — **P1**

* **Evidence:** `ui/search.dart:523-534`:
  ```
  if (!snapshot.hasData) return spinner;
  if (snapshot.hasError) return const ErrorScreen();   // unreachable
  ```
* **Impact:** with no network (or a Deezer error) the user stares at a spinner indefinitely; the only escape is back.
* **Fix:** store the future in state (`late Future<SearchResults> _future;` created in `initState`/on query change), branch `hasError` first, add retry, and use the shared `AsyncView` from M3.
* **Verify:** widget test with a throwing fake repository; manual airplane-mode search.

### BUG-05 · `late` locals read after a failed request → crash — **P1**

* **Evidence:**
  * `ui/search.dart:121-131`: `late List sugg; try { sugg = await … } catch { print } if (!_cancel) setState(() => _suggestions = sugg);`
  * `ui/library.dart:393-404`: `late Playlist p; try { p = … } catch { print } setState(() { tracks = p.tracks!; trackCount = p.trackCount; });`
* **Impact:** `LateInitializationError` (uncaught) on any network/API failure on these paths — suggestions typing while offline, sorting/loading the full favourites list.
* **Fix:** make the variables nullable (`Playlist? p; List? sugg;`) and return early on failure with a visible error; add a lint/CI check for `late` locals assigned only in `try`.
* **Verify:** unit/widget tests with failing repository; repro by disabling network while typing a search.

### BUG-06 · No HTTP timeouts → hung spinners and stuck flows — **P1**

* **Evidence:** every `http.get`/`http.post` in `api/deezer.dart`, `api/deezer_login.dart`, `api/spotify.dart`, `ui/updater.dart` lacks `.timeout(...)`; the single timeout in the app is `audio_service.dart:431` (player readiness).
* **Impact:** on a captive portal / stalled connection, authorisation, home, search, album loads and the update check never complete; UI shows spinners forever; download queue stalls without an error.
* **Fix:** central `ApiClient` with 15 s connect/30 s total timeouts, `SocketException`/`TimeoutException` → typed `AppFailure`, one retry with backoff for idempotent GETs.
* **Verify:** unit tests with a mock client that delays; manual test with a proxy that drops packets.

### BUG-07 · Fixed stream-server port, silent failure — **P1**

* **Evidence:** `StreamServer.start()` (`:38-48`) catches every exception and only `printStackTrace()`s; `MainActivity.java:193-217` reports success to Dart regardless; `audio_service.dart:_getTrackUrl` always builds `http://localhost:36958/...`.
* **Impact:** if the port is occupied (another instance, another app), *all* playback and offline playback fail with no message.
* **Fix:** ephemeral port + handshake result to Dart (`startServer` returns the port/token, or throws on failure); surface a player error state; retry on a new port.
* **Verify:** bind 36958 in a test harness before launching; assert playback still works and an error is shown when the server cannot start.

### BUG-08 · `DownloadsDatabase` migration is broken — **P2**

* **Evidence:** `DownloadsDatabase.java:40-45`: `onUpgrade`/`onDowngrade` call `onCreate(db)`, which runs `CREATE TABLE Downloads` without `DROP TABLE` → `SQLiteException: table Downloads already exists`.
* **Impact:** latent — any future DB version bump crashes the download service on first launch after upgrade, likely losing the queue.
* **Fix:** drop/recreate or write real migrations; add a version-2 smoke test path.
* **Verify:** instrumented test opening v1 DB then v2 helper.

### BUG-09 · Visualizer is dead code shipped as a feature — **P2**

* **Evidence:** `service/audio_service.dart:947-963` — the entire body of `startVisualizer()` is commented out; `ui/lyrics.dart:143-160` consumes `visualizerStream`, which never emits, then computes `width = screenWidth / data.length - 0.25` (division by zero → `Infinity`).
* **Impact:** a user-facing toggle does nothing; potential layout weirdness; false advertising in settings.
* **Fix (preferred):** remove the toggle and the stream until implemented (needs approval to remove a feature) or implement it with a supported API (`just_audio` visualizer branch is not viable on stable). Document as removed in `CHANGELOG.md`.
* **Verify:** manual toggle check; widget test that the lyrics screen renders without the visualizer.

### BUG-10 · PlayerBar rebuilds 4×/s and leaks focus nodes — **P2**

* **Evidence:** `ui/player_bar.dart:58` `Stream.periodic(const Duration(milliseconds: 250))` inside a `StreamBuilder`; `:34` `var focusNode = FocusNode();` created per `build()` and never disposed.
* **Impact:** continuous rebuilds while audio is idle (battery/CPU), leaked `FocusNode`s, and DPAD focus is lost every 250 ms on TV.
* **Fix:** subscribe to `audioHandler.playbackState`/`positionStream` and rebuild only while playing; hoist the `FocusNode` into `State` and dispose it; use `ValueListenableBuilder`/`StreamBuilder` on the merged playback stream.
* **Verify:** DevTools rebuild counter; manual TV focus test.

### BUG-11 · Lyrics starts a new periodic timer per update — **P2**

* **Evidence:** `ui/lyrics.dart:49-60` `_updateLyricsState()` calls `_startSyncTimer()`; `:94-113` `_startSyncTimer()` creates `Timer.periodic(350 ms)` and assigns it to `_timer` **inside** the callback, so each call adds another timer and only the last is cancelled in `dispose()`.
* **Impact:** duplicated `setState`/`animateTo` per tick, jittery scrolling, battery drain, work after dispose.
* **Fix:** cancel before starting (`_timer?.cancel()`), assign the timer at creation; stop the timer when the widget is not visible (`VisibilityDetector` already a dependency); guard `setState` with `mounted`.
* **Verify:** widget test counting timer callbacks; manual scroll smoothness.

### BUG-12 · Per-tile subscriptions and DB lookups in long lists — **P2**

* **Evidence:** `ui/tiles.dart:33-56` — every `TrackTile` subscribes to `audioHandler.mediaItem` and calls `downloadManager.checkOffline(...)`; the tracks screen renders **all** items with `ListView(children: List.generate(...))` (`library.dart:545-580`), and the album/artist lists use `ListView.builder(shrinkWrap: true, physics: NeverScrollableScrollPhysics())` inside the parent list (`library.dart:829-856`), which still lays out every row; downloads render whole state groups as `Column`s (`downloads_screen.dart:180-198`).
* **Impact:** for 500–1000 favourites: 500–1000 stream subscriptions, 500–1000 async offline checks, full non-lazy layout, `setState` on every tile at each track change → jank, memory pressure, slow first frame.
* **Fix:** provide current track + offline-ID set from a `ChangeNotifier`/provider (M3/M5); use `ListView.builder` with `itemCount`; memoise offline checks in a `Set<String>`.
* **Verify:** profile with a 1000-track favourites list (frame times, memory); before/after screenshots of rebuild counts.

### BUG-13 · Sorting crashes on missing metadata — **P2**

* **Evidence:** `ui/library.dart:277` `a.addedDate!.compareTo(b.addedDate!)`; `:283-285` `a.artists![0].name!`; same pattern in `details_screens.dart:775`. `Track.fromSQL`/`fromPrivateJson` can leave these null/empty.
* **Impact:** `Null check operator used on a null value` / `RangeError` when sorting a library containing a track without `DATE_ADD` or artists (common for local/fallback tracks).
* **Fix:** compare with null-safe fallbacks (`(a.addedDate ?? 0).compareTo(...)`, `a.artists?.firstOrNull?.name ?? ''`), add a stable tiebreaker on id.
* **Verify:** unit tests over `Sorting`/comparator with null and empty metadata.

### BUG-14 · Empty-library and empty-list crashes — **P2**

* **Evidence:** `ui/library.dart:93-100` `deezerAPI.libraryShuffle()` result → `tracks[0].id!`; `main.dart:305` `p.tracks?[0].id` for the Favorites quick action; `android_auto.dart:195-208` similar indexing; `audio_service.dart:871` `tracks[0].id` in `playMix`.
* **Impact:** `RangeError` from a home-screen shortcut or a new account with no favourites — i.e. a crash on first use of Flow/Favorites for new users.
* **Fix:** shared `playFirstOrShowEmpty(...)` guard; validate non-empty lists before indexing; add tests.
* **Verify:** widget tests with empty lists; manual test with a fresh account.

### BUG-15 · Destructive "Clear all" with no confirmation — **P2**

* **Evidence:** `ui/downloads_screen.dart:96-106` — `IconButton` deletes all `ERROR`, `DEEZER_ERROR`, `DONE` **and** `NONE` (queued) download **records** immediately, while single-item delete (`DownloadTile.onClick`) shows a confirmation dialog. On the Java side `SERVICE_REMOVE_DOWNLOADS` (`DownloadService.java:807-829`) deletes only database rows.
* **Impact:** accidental loss of the queue and download history with no confirmation, inconsistent with the app's own confirmation pattern; because files are not deleted (see BUG-21), the user also ends up with untracked files on disk.
* **Fix:** confirmation dialog listing what will be removed (queue/finished/failed counts); separate actions; undo where feasible.
* **Verify:** widget test asserting the dialog appears and nothing is deleted on cancel.

### BUG-16 · `mounted`/`setState` discipline gaps — **P3**

* **Evidence:** `ui/downloads_screen.dart:28-33` `_load()` calls `setState` without a `mounted` check (also after `dispose`); `ui/lyrics.dart:52` and `:68-74` `setState` after `await`; `ui/details_screens.dart:33-43` `setState` after `await` without `mounted`; `ui/updater.dart:114-119` `setState` after `await`.
* **Impact:** "setState() called after dispose()" exceptions during fast navigation (silent in release, noisy in debug, occasionally leaves UI stale).
* **Fix:** consistent `if (!mounted) return;` after every await; enable the `use_build_context_synchronously` lint (already via flutter_lints) and fix all violations; add a CI lint gate.
* **Verify:** `flutter analyze` clean; stress-test by rapidly entering/leaving downloads, lyrics and details.

### BUG-17 · Updater downloads without integrity verification — **P2**

* **Evidence:** `ui/updater.dart:82-120` — `http.get` of `browser_download_url`, writes to external files, `OpenFilex.open(path)`; no hash/signature check; polling loop `Future.doWhile` busy-loops on `file.length()` with `setState` while `res.stream.pipe(fileSink)` runs; `size!` will throw if `Content-Length` is absent.
* **Impact:** UI jank during download; potential install of a tampered APK; crash on servers without `Content-Length`.
* **Fix:** stream with `contentLength != null` guard, throttle progress updates, verify SHA-256 published in the release notes (or rely on Android signature check by installing over the same package), enforce HTTPS, and add a Wi-Fi-only preference.
* **Verify:** unit test for the SHA/format logic; manual update run over a throttled connection.

### BUG-18 · i18n gaps — **P3**

* **Evidence (scripted):** 11 `.i18n` literals missing from `languages/en_us.dart` (e.g. `App icon`, `Apply`, `Download externally`, `Select app icon`, `Select country`, `Storage Permission Required`, `Mix based on`, `Playlist menu`, two long storage-permission strings that differ from the translated originals); locales `ur-PK` 3.9 % and `te-IN` 7.8 % coverage; stale keys remain in `en_us` (`Reverse`, `Convert`, `Download only`, …).
* **Impact:** untranslated English text leaks into all localisations; two locales are effectively English with a translated label.
* **Fix:** add the missing en-US entries, sync with Crowdin, hide locales below a coverage threshold (or mark them "incomplete"), and add a CI check comparing code literals to `en_us`.
* **Verify:** the same scripted check in CI must report 0 missing keys.

### BUG-19 · Settings that do nothing / are misleading — **P3**

* **Evidence:** `proxyAddress` exists in the model but its UI is commented out (`settings_screen.dart:789-830`) and nothing consumes it; `lyricsVisualizer` (BUG-09); Appearance labels a toggle "Warning: might be buggy" (`settings_screen.dart:337`); `AudioQuality.ASK` only affects downloads, not streaming.
* **Impact:** user distrust; dead configuration surface.
* **Fix:** remove dead settings (approval needed) or implement them; remove self-deprecating copy in favour of honest descriptions.
* **Verify:** code search shows zero unreferenced settings keys.

### BUG-20 · Gallery/colour extraction null assertions — **P3**

* **Evidence:** `ui/cached_image.dart:24,29` `paletteGenerator.colors.first`; `ui/player_screen.dart:83,95` `palette.dominantColor!`.
* **Impact:** unhandled async exception (and missing background) when album art is missing or fails to load — common with custom/fallback tracks.
* **Fix:** null-safe palette handling with a deterministic fallback colour from the theme.
* **Verify:** unit test with an empty palette; manual test with a track whose art 404s.

### BUG-21 · "Delete download" does not delete the file; two sources of truth for offline state — **P2**

* **Evidence:** `DownloadService.java:769-780` (`SERVICE_REMOVE_DOWNLOAD`) and `:807-829` (`SERVICE_REMOVE_DOWNLOADS`) delete only rows from the Java `downloads` DB; the media file is never touched. The confirmation dialog reads "Are you sure you want to delete this download?" (`downloads_screen.dart:262-283`). Offline state is tracked **twice**: Java `downloads` (queue/history) and Dart `offline2.db` (`offline` flag) plus the physical file at `offline/<id>`; `removeOfflineTracks` (`download.dart:498-526`) deletes the file and updates `offline2.db`, but never touches the Java DB.
* **Impact:** storage is not reclaimed when a user "deletes" a download from the Downloads screen; files become orphaned (still playable by path, invisible to the app's offline index); the two DBs can disagree about what is offline.
* **Fix:** define one owner for offline media (recommend the Dart `offline2.db` + file system, with Java reporting only transfer state); make delete remove the file (or clearly say "Remove from list") and reconcile the other DB; add an orphan sweep on startup.
* **Verify:** integration test: download → delete → assert file gone, both DBs consistent; manual check of storage before/after.

---

## 2. Technical debt register

| ID | Debt | Impact | Effort | Recommended milestone |
|---|---|---|---|---|
| TD-01 | No tests, no CI, no `pubspec.lock`, uninitialised submodules, `.env`/`env.g.dart` missing | Cannot verify anything; fresh clone does not build; regressions unbounded | M | M0 |
| TD-02 | `useMaterial3: false` + four hand-copied `ThemeData` blocks (`settings.dart:227-490`) | Inconsistent styling; every theme change ×4 | M | M3 |
| TD-03 | `settings_screen.dart` (1,956 LOC), `library.dart` (1,373), `details_screens.dart` (1,288), `audio_service.dart` (994) | Unreviewable, untestable units; merge conflicts | L | M4/M6 |
| TD-04 | Business logic inside widgets (paging, sorting, offline fallback, API mutations) | Not unit-testable; duplicated across screens | L | M6 |
| TD-05 | Global mutable singletons + `late Function` globals (`updateTheme`, `logOut`, `updateColor`) | Initialisation-order crashes; hidden coupling | M | M3/M6 |
| TD-06 | No shared loading/empty/error components; 3 idioms, `ErrorScreen` without retry | Inconsistent UX; bug class BUG-04 | S | M3 |
| TD-07 | Navigation: inline `Navigator.push` in ~40 places, two navigators, `mainNavigatorKey`/`customNavigatorKey` globals | Deep links open over tabs; no route guards | M | M3 |
| TD-08 | Playback resolves the whole queue eagerly before playing (`_itemsToSources`) | Multi-second start for large queues | M | M5 |
| TD-09 | Two SQLite DBs with no migration path; JSON files without schema versions | Fragile upgrades | M | M1/M6 |
| TD-10 | Dead code: `utils/blowfish.dart` (1,170 LOC), `utils/math_utils.dart`, 5 unused routes, `QueueState.empty`, dead settings | Maintenance noise, binary size | S | M6 |
| TD-11 | Unused dependencies: `animations`, `encrypt`, `pointycastle`; git dependency `disk_space_plus`; 5 path submodules | Build fragility, supply-chain surface | S | M0/M6 |
| TD-12 | Non-virtualised lists everywhere (`ListView(children:)`) | Jank on large data | S–M | M5 |
| TD-13 | No crash reporting / `FlutterError.onError` / `ErrorWidget.builder` | Failures invisible; bug reports unusable | S | M1 |
| TD-14 | `flutter_screenutil` used only in the player, initialised in `build` | Inconsistent responsiveness | S | M3/M7 |
| TD-15 | `crowdin.dart` (~600 KB of Dart map literals) compiled into the app | APK size and first-use parse cost | M | M7 (evaluate ARB/`flutter_localizations`) |
| TD-16 | Release build has `minifyEnabled false`, `shrinkResources false`, no R8 rules | Larger APK, no obfuscation | S | M8 |
| TD-17 | `GoogleFonts` resolves fonts at runtime | First-use network dependency; blank/fallback fonts offline | S | M3 |
| TD-18 | Implicit Dart↔Java contract (JSON settings blob + int opcodes) undocumented | Any change requires reading both sides | S (docs) | M0/M6 |

---

## 3. Prioritised fix order (contained → broad)

1. BUG-03, BUG-04, BUG-05, BUG-06, BUG-14 (crash/error containment) — no UI redesign, cheap, high user value.
2. BUG-01, BUG-02 (+ cleartext scoping) — security, medium effort, contains process-boundary work.
3. BUG-07, BUG-08, BUG-17 (service reliability/update integrity).
4. BUG-09, BUG-15, BUG-19, BUG-18 (honesty/consistency/confirmation/localisation).
5. BUG-10, BUG-11, BUG-12, BUG-13 (performance/correctness of lists, player, lyrics).
6. BUG-16, BUG-20 (hygiene, polish).
7. Test harness and architecture seam (TD-01, TD-04, TD-05) run *alongside*, starting in M0.
