# ReFreezer — Features Inventory

**Baseline:** commit `2bb8009`, app version `0.7.15`
**Method:** static reading of all Dart/Java sources (see `PROJECT_AUDIT.md` §11). No runtime testing was possible in this environment (`DEVELOPMENT_STATUS.md`).

**Status legend**

| Status | Meaning |
|---|---|
| **IMPLEMENTED** | Code path exists, is reachable, and appears coherent on inspection. Runtime confirmation still required. |
| **PARTIAL** | Works for the main case; known gaps or fragile branches. |
| **BROKEN (static)** | A defect is visible in the code that will predictably fail (crash, unreachable branch, no-op). |
| **DEAD** | Code/setting exists but is unreachable or inert. |
| **UNVERIFIED** | Cannot be judged statically; needs a device/API. |

---

## 1. Feature matrix

### 1.1 Authentication & account

| Feature | Status | Evidence / notes |
|---|---|---|
| Login with raw ARL token | IMPLEMENTED | `login_screen.dart:196-230`; length sanity check (175/192) in `_update()` |
| Login with email + password | PARTIAL | `deezer_login.dart:20-74`; md5-hashed password to `connect.deezer.com/oauth/user_auth.php`, browser UA + spoofed client IP. Depends on an unsupported Deezer flow → UNVERIFIED whether it still works |
| Login via in-app browser (WebView) | PARTIAL | `login_screen.dart:294-340`; scrapes `arl` from `intent://…page.link?link=…` redirect; breaks silently if Deezer changes the flow |
| Country availability check | IMPLEMENTED | `deezer.dart:187-197` + blocking dialog on first launch (`login_screen.dart:48-70`) |
| Logout | PARTIAL | `main.dart:160-185`: stops audio, kills download service, wipes cache, `Restartable.restart()` (soft restart, not process restart) |
| Session expiry handling | PARTIAL | `ErrorScreen` shows an ARL hint only after >3 errors (`error.dart:18-31`); no proactive re-auth, no global 401 detection |
| Multi-account | MISSING | Single token |

### 1.2 Discovery

| Feature | Status | Evidence / notes |
|---|---|---|
| Deezer home page (rows + grids, "show more") | IMPLEMENTED | `home_screen.dart:102-300`; cached in `homescreen.json`, then replaced by API result |
| Home page offline | PARTIAL | `HomePage.load()` used first; on corrupt file the exception is swallowed and the screen spins if the API also fails |
| Personalised channels / "Show more" drill-down | IMPLEMENTED | `HomePageScreen(channel:)` |
| Flow + flow variants | IMPLEMENTED | `playFromSmartTrackList` (`audio_service.dart:905-940`); queue auto-extends at the end (`_onQueueEnd`) |
| Mood/theme smart track lists | IMPLEMENTED | `DeezerFlow` tiles → `playFromSmartTrackList` |
| Browse categories (search screen cards) | IMPLEMENTED | `search.dart:460-505` |

### 1.3 Search

| Feature | Status | Evidence / notes |
|---|---|---|
| Full search (tracks, albums, artists, playlists, shows, episodes) | IMPLEMENTED | `deezer.dart:200-204` → `SearchResults.fromPrivateJson` |
| Search suggestions (debounced) | **BROKEN (static)** | `search.dart:113-131`: `late List sugg` is read even when the request throws → `LateInitializationError` |
| Search history (persisted, per-item delete) | IMPLEMENTED | `cache.addToSearchHistory`; stored as typed items |
| Search results screen | **BROKEN (static)** | `search.dart:523-531`: `hasError` branch unreachable (spinner forever on failure); future created in `build()` → refetch on every rebuild |
| Offline search (local DB) | PARTIAL | `downloadManager.search` only when `_offline` was set at init from a connectivity snapshot |
| Deep link / paste-a-URL search | IMPLEMENTED | `openScreenByURL` (`search.dart:26-51`), Deezer + Spotify links |

### 1.4 Library

| Feature | Status | Evidence / notes |
|---|---|---|
| Favourite tracks (paged) | IMPLEMENTED | `LibraryTracks._load` paging via `playlistTracksPage` |
| Favourite tracks offline fallback | PARTIAL | Falls back to `getOfflinePlaylist` only when a page request returns `null` |
| Sorting (default/alphabetic/artist/reverse) + persisted | PARTIAL | `library.dart:270-300`; `a.addedDate!` and `a.artists![0].name!` unguarded → possible crash; "load all" uses an unassigned `late Playlist` (`:393-404`) |
| Favourite albums (online + offline sections) | PARTIAL | `LibraryAlbums`/`AlbumList`; null-safe sorting and `ListView.builder`, but load errors are swallowed into an empty list (no empty/error state) |
| Favourite artists | PARTIAL | `_LibraryArtistsState`; inline spinner, load failures are logged and leave an empty list with no message |
| User playlists (create/edit/delete/add/remove tracks) | IMPLEMENTED | `menu.dart` + `deezer.dart` mutations |
| Library shuffle | PARTIAL | `library.dart:93-100`: `tracks[0]` without emptiness check → `RangeError` on empty library |
| Playback history | IMPLEMENTED | `cache.history` (full `Track` objects, unbounded) + `HistoryScreen` |
| Library stats (offline counts, free space) | IMPLEMENTED | `downloadManager.getStats()` (Java/Dart DB + disk space) |

### 1.5 Details

| Feature | Status | Evidence / notes |
|---|---|---|
| Album details (discs, fav, offline, download) | IMPLEMENTED | `details_screens.dart:21-258`; shows error screen on API failure |
| Artist details (top tracks, albums, related, radio, shuffle) | IMPLEMENTED | `:318-580` |
| Discography with pagination | IMPLEMENTED | `:582-750` |
| Playlist details (pagination, sorting, edit, offline/download) | IMPLEMENTED | `:752-1102` |
| Show / episodes (download, external episode) | PARTIAL | `:1167-1288`; episodes with `showUrl` bypass the stream server |
| "Make offline" / "Download" conflation | PARTIAL | Two different concepts (private vs external) surfaced as "Offline" / "Download" with no explanation |

### 1.6 Playback

| Feature | Status | Evidence / notes |
|---|---|---|
| Play/pause, next/previous (5 s rewind rule) | IMPLEMENTED | `audio_service.dart:340-365` |
| Queue: add, play next, reorder, remove, clear | IMPLEMENTED | `:263-330`, `player_screen.dart:1054-1200` |
| Shuffle / repeat (all, one) | IMPLEMENTED | `:355-375`; interacts with shuffle-index remapping |
| Saved queue restore (index + position + loop) | IMPLEMENTED | `playback.json`, `:735-785` |
| Stream quality by network (mobile/wifi) | IMPLEMENTED | `getStreamQuality` (`:568-576`) — note: anything that is not Wi-Fi counts as mobile; no ethernet/VPN distinction |
| FLAC / 320 / 128 | UNVERIFIED | Depends on Deezer account tier; `getQualityInt` maps 128→1, 320→3, FLAC→9 |
| Fallback track when original unavailable | IMPLEMENTED | `playbackDetailsFallback` + `fallbackId` |
| Offline playback | IMPLEMENTED | `_getTrackUrl` checks `offline/<id>` then streams from the local server |
| Equalizer (system EQ binding) | PARTIAL | `audio_service.dart:159-186`: relies on `EqualizerFlutter.open` with the platform session; no UI/state persistence, no presets |
| Sleep timer | IMPLEMENTED | `menu.dart:596-682` + `cache.sleepTimerTime` |
| Wakelock toggle | IMPLEMENTED | `menu.dart` + `cache.wakelock` |
| Playback error surfacing | **BROKEN (static)** | Errors are logged and playback stopped (`:614-625`); user sees nothing |
| Visualizer | **DEAD** | `startVisualizer()` body is commented out (`:947-963`); UI draws from a stream that never emits, and divides by `data.length` (0) |
| Android Auto | PARTIAL | `android_auto.dart` media tree; `print()` diagnostics; direct API calls in browse callbacks (no error handling → empty browse tree on failure) |
| Android TV/DPAD focus | PARTIAL | Hand-rolled in `main.dart:340-400` plus per-widget `FocusNode`s; depends on tree shape |
| Lyrics: synced auto-scroll + tap-to-seek | PARTIAL | `lyrics.dart`; **new `Timer.periodic` per lyrics update** (`:94-113`) → duplicate timers; no `mounted` checks |
| Lyrics: unsynced fallback, legacy API fallback | IMPLEMENTED | `deezer.dart:342-410` |
| Last.fm scrobbling | PARTIAL | `authorizeLastFM` (`:800-816`) + scrobble at play; auth failure only shows a toast; no "now playing" update |
| Deezer listen logging | IMPLEMENTED | At 75 % of duration, once per track (`:188-208`) |

### 1.7 Downloads / offline storage

> Note (2026-11-08): the queue-control, "clear all" and DB-migration rows below describe the audited
> baseline; they were superseded by the downloader upgrade (`CHANGELOG.md`).

| Feature | Status | Evidence / notes |
|---|---|---|
| External downloads (to Music folder / SAF) | IMPLEMENTED | Java `DownloadService`; permission gate `FileUtils.checkExternalStoragePermissions` |
| Private "offline" downloads (app storage) | IMPLEMENTED | `offline/<trackId>` via `DownloadManager` + Java |
| Multi-threaded downloads (configurable threads) | IMPLEMENTED | `downloadThreads` default 2 |
| Tagging (ID3v2.3 / FLAC), artwork, lyrics embedding | IMPLEMENTED | `Deezer.java` + `jaudiotagger` + `extension-flac.aar` |
| Filename/folder templating (`%artist%`, `%title%`, playlist/disc folders) | IMPLEMENTED | `DownloadManager._generatePath` + template dialog |
| `.nomedia` support | IMPLEMENTED | setting + Java |
| Queue controls: pause/resume/stop, retry failed, clear by state | IMPLEMENTED | `downloads_screen.dart`, `DownloadService` opcodes |
| Per-download progress + notification | IMPLEMENTED | EventChannel `onProgress` (500 ms loop), notification per download |
| Download log viewer | IMPLEMENTED | `download.log` in-app |
| Download whole album / playlist | IMPLEMENTED | `DownloadManager.addOfflineAlbum` / `addOfflinePlaylist`; details screens and long-press menus |
| Download whole artist (discography + top tracks) | IMPLEMENTED | `DownloadManager.downloadArtist`; artist screen button and long-press menu; confirm + progress dialogs |
| Storage-space pre-check | PARTIAL | The Downloads screen shows free space vs. the estimated need for the queue; nothing blocks enqueueing |
| "Clear all" safety | **BROKEN (static)** | `downloads_screen.dart:96-106` deletes all states with no confirmation (single delete does confirm) |
| Background continuation | UNVERIFIED | `START_STICKY` + separate process + `stopWithTask=false`; behaviour after reboot/task removal untested |
| DB migration path | **BROKEN (static)** | `DownloadsDatabase.onUpgrade` → `onCreate` without dropping tables |

### 1.8 Import & integrations

| Feature | Status | Evidence / notes |
|---|---|---|
| Spotify playlist import V1 (paste public playlist URL, scrape embed page) | PARTIAL | `spotify.dart:14-90`; brittle HTML scraping |
| Spotify OAuth importer V2 (client id/secret, local redirect server) | PARTIAL | `SpotifyAPIWrapper` binds `localhost:42069`; credentials persisted in plaintext settings |
| Import progress + per-track status | IMPLEMENTED | `importer.dart` stream; ERROR/OK states |
| Import → optional download | IMPLEMENTED | `Importer.download` |
| Tidal import | MISSING | Only Spotify exists (README/marketing references "importer") |
| Update check + in-app APK download | PARTIAL | `updater.dart`; GitHub API unauthenticated (rate-limited), no APK integrity check, APK stored in external files |
| Quick actions (Flow / Favorites shortcuts) | IMPLEMENTED | `main.dart:283-310`; `p.tracks?[0]` unguarded |
| Launcher icon switching (3 aliases) | IMPLEMENTED | `ChangeIconPlugin.java` + activity-aliases; requires app restart |
| Display refresh-rate mode selection | IMPLEMENTED | `flutter_displaymode`, `settings.displayMode` |

### 1.9 Appearance & localisation

| Feature | Status | Evidence / notes |
|---|---|---|
| 4 themes (Light, Dark, Deezer, Black) + system theme | IMPLEMENTED | `settings.dart:227-490` (four near-duplicate `ThemeData` blocks) |
| Primary colour picker | IMPLEMENTED | `flutter_material_color_picker`; no contrast guard |
| "Use album art primary colour" | PARTIAL | `settings.dart:203-219`; labelled "Warning: might be buggy"; depends on `paletteGenerator.colors.first` (throws on empty palette) |
| Gradient / blurred player background | IMPLEMENTED | `player_screen.dart:57-105`; decodes full image on UI isolate; `dominantColor!` unguarded |
| Font selection (Deezer + Google Fonts) | IMPLEMENTED | Runtime `GoogleFonts.getTextTheme` (Google Fonts fetched at runtime → needs network on first use; no bundled fallback) |
| 31 languages | PARTIAL | Median 99.4 % coverage; `ur-PK` 3.9 %, `te-IN` 7.8 %; 11 referenced strings missing from English table |
| Text scaling / accessibility (TalkBack, font size) | UNVERIFIED | Many explicit `fontSize` values and fixed-height rows; semantic labels present on most icon buttons |

---

## 2. Screen inventory

| Screen | File:line | Entry points | State handling | Notable issues |
|---|---|---|---|---|
| Splash / initialisation | `main.dart:419-446` | app start | `FutureBuilder` on `_init()` | Spinner only; a hung `_init()` never resolves |
| Login | `login_screen.dart:16-293` | no ARL | `setState` | Controllers/FocusNode created in `build()`; `_init()` unguarded async |
| Email login dialog | `login_screen.dart:342-440` | Login | `_loading` | No validation, raw exception text in dialog |
| Browser login | `login_screen.dart:294-340` | Login | none | No URL allowlist; silent failure |
| Home | `home_screen.dart:18-37` | tab 1 | `_HomePageScreenState` | Sections built eagerly in a `Column` (no lazy list); no empty state distinct from the spinner |
| Search | `search.dart:53-458` | tab 2 | `setState` | Suggestions crash path; offline flag is a snapshot |
| Search results | `search.dart:506-866` | search / browse | `FutureBuilder` in `build` | Error branch unreachable |
| Library hub | `library.dart:63-256` | tab 3 | stateless + conditional tiles | Stats via `FutureBuilder` |
| Library tracks | `library.dart:257-623` | hub | `setState` + paging | Non-virtualised list; sorting crash risks |
| Library albums/artists/playlists | `library.dart:624-1319` | hub | `setState` | Inline spinner; failures leave a silent empty list (no error/empty state); `ListView.builder(shrinkWrap: true, physics: NeverScrollable)` inside the parent list still lays out every row |
| History | `library.dart:1320-1373` | hub | `setState` | |
| Album details | `details_screens.dart:21-258` | home/search/library | `_loading`/`_error` | Spinner replaces whole screen |
| Artist details | `details_screens.dart:318-580` | search/library | `_loading` | |
| Discography | `details_screens.dart:582-750` | artist | paging | |
| Playlist details | `details_screens.dart:752-1102` | home/search/library | paging + sort | |
| Show details | `details_screens.dart:1167-1288` | home/search | `setState` | |
| Player (vertical/horizontal) | `player_screen.dart:41-457` | player bar tap/swipe | `StreamBuilder` + `setState` | `ScreenUtil.init` in build; null art/dominant colour assertions |
| Queue | `player_screen.dart:1054-1200` | player menu | stream sub + reorder | |
| Lyrics | `lyrics.dart:16-236` | player | `setState` + timer | Timer leak; dead visualizer |
| Downloads | `downloads_screen.dart:14-365` | app bar icon (3 tabs), library | event stream | No empty state; destructive "clear all" |
| Download log | `downloads_screen.dart:314-365` | downloads | `setState` | |
| Settings hub + 10 sub-screens | `settings_screen.dart` | app bar icon | `setState` | No search/grouping/reset; immediate persistence |
| Importer (V1/V2/status/settings) | `importer_screen.dart` | settings | `setState` + streams | 710 LOC, two parallel implementations |
| Updater | `updater.dart:24-250` | settings/about | `_loading`/`_error` | No integrity check; polling download loop |
| Credits/About | `settings_screen.dart:1712+` | settings | static | |
| Application log | `log_screen.dart` | settings | `setState` | |
| Android Auto tree | `android_auto.dart` | system | async browse | `print()`s; no error handling |

---

## 3. Settings inventory

| Group | Items |
|---|---|
| **General** | Log out, last.fm login/logout, language, "Allow screen to turn off", equalizer enable, ignore interruptions, app version, logs, importer entry, storage info, credits |
| **Downloads** | Path picker, filename template, singleton template, artist/album/disc/playlist folders, overwrite, threads (1–8), download lyrics, track cover, album cover, art resolution, `.nomedia`, artist separator, ID3/FLAC tag selection (16 tags), clear history |
| **Appearance** | Theme (4), use system theme, app icon (3), font (Google Fonts + Deezer), primary colour, colour from art, player gradient, blur background, visualizer (**dead**), display mode/high refresh |
| **Quality** | Mobile streaming, Wi-Fi streaming, offline, external downloads (each MP3 128/320/FLAC; downloads also "ask") |
| **Deezer** | Content language (~30), content country (~200), log listens, proxy (**dead/commented**) |
| **Updates** | Check + download APK |
| **About** | Version, credits, links |

Count: ~60 user-visible controls across 8 pages. No search, no reset-to-default, no import/export, no explanation for jargon (ARL, external downloads, Flow).

---

## 4. Journeys with friction points

1. **Install → first sound**: splash (blocking init) → login (3 unexplained options) → country modal → home load (cache then API, silent failure) → tap a tile → details (spinner) → play (queue resolution delay). *~6 interactions, 3 places where nothing tells the user what is happening.*
2. **Find a song**: Search tab → type → suggestions (crash risk on failure) → results (spinner forever if offline) → tap one of the three visible tracks (the full result list becomes the queue, but only three are shown, so the queue's contents are invisible until "show all tracks").
3. **Save for offline**: open album → "Download" vs "Make offline" (unexplained) → storage permission dialog → toast → Downloads screen (no empty state if nothing queued) → progress dots. No space check, no success notification outside the download notification.
4. **Listen offline**: library → tracks (offline fallback only after a failed API call) → play via local server; if the server failed to bind, playback silently fails.
5. **Manage library**: favourite from Search → Library does not know until refetch; sorting resets/reloads full playlist; removing a favourite updates only the local list.
6. **Personalise**: Settings → Appearance (12 controls on one page) → language change (partially applies, restart hint) → icon change (app exits to apply).
7. **Update**: Settings → Updates → GitHub fetch → changelog → download APK → system installer. No verification, no wifi-only guard.

---

## 5. Feature gaps worth stating explicitly

* No offline indicator, no download-space check, no "download all favourites", no batch retry beyond "restart failed".
* No per-track "download quality" override, no crossfade/gapless controls, no playback speed.
* No Play Store distribution path (self-update + permissions), no crash reporting, no analytics (acceptable), no privacy policy.
* No tablet/foldable layout beyond orientation branching; no dynamic colour (Material You).
* No tests, no CI, no build reproducibility (see `UPGRADE_ROADMAP.md` M0).
