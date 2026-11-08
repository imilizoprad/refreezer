# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

The project previously tracked changes through GitHub releases only; this file starts at the audited baseline.

---

## [Download upgrade + Downloads redesign] — 2026-11-08

Native downloader reliability, queue management, database migration and a redesigned Downloads
experience. **Static-only verification** (see `DEVELOPMENT_STATUS.md` §3): no build, analyse or
device run was possible in this environment.

### Added

- **Download queue controls**: pause/resume per job, pause/resume the whole queue, cancel (kept in
  history), retry one, retry all failed, priority (High/Normal/Low), move-to-front.
- **Retry policy**: classified failures (`network`, `timeout`, `server`, `auth`, `storage`,
  `permission`, `unavailable`, `processing`), bounded exponential backoff with jitter, `Retry-After`
  support, per-job retry budget (0–10, configurable in Settings), no retries for permanent failures.
- **Recovery**: running state persisted across process death, interrupted jobs recovered on start,
  validated `Range` resume (206 only), orphaned temporary files purged at service start.
- **Safe finalisation**: staging file in the destination folder + atomic rename; a job is only
  `DONE` when a complete file exists; metadata (cover/lyrics/tags) failures keep the audio and are
  reported as `metadataWarning` instead of failing the download.
- **Aggregate notifications** (progress + "Downloads finished"), per-track notifications opt-in
  (`Summary` / `Every track` / `None`), plus a `Download results` channel.
- **Database v2** (`DownloadsDatabase`): additive columns for priority, retries, retry time, error
  kind/message, expected size, creation order, group and metadata warning; idempotent self-healing
  migration; downgrade preserves data.
- **Dart layer**: `lib/api/download_models.dart` (pure, testable model), `DownloadController`
  (single source of truth), new download API surface, `DownloadEnqueueResult`, `DownloadSummary`,
  storage estimation.
- **Design system**: `lib/ui/design/tokens.dart` and `components.dart` (obsidian/editorial tokens,
  type scale, progress rule, status, buttons, sheets, filter bar, empty/error/skeleton states,
  reduced-motion support).
- **Redesigned Downloads screen**: overview header, filters with counts, search, grouped sections,
  per-row speed/ETA/progress, swipe actions, batch selection, confirmations, undo for cancel,
  separate "remove entry" vs "delete file", empty/loading/error states.
- **Tests** (written, not executed here): `test/download_models_test.dart`,
  `test/download_queue_test.dart`.

### Changed

- `DownloadService`: main-thread queue ownership replaces the cross-thread re-entrancy hack; the
  service only stops when the queue is idle; worker reads are disconnected immediately on
  pause/cancel; concurrency is clamped to 1–8; downloads do not start without credentials.
- `MainActivity`: `addDownloads` returns `{added, existing, requeued}` and deduplicates on
  track + destination + quality; new channel methods for the queue controls; state-change events
  carry queue counters and `blockReason`; progress events carry `speed`.
- `Download`: named-column SQL parsing (robust to older rows), new scheduling/diagnostic fields.
- Settings: `downloadMaxRetries` and `downloadNotifications` (generated JSON updated by hand).

### Fixed (by construction, needs device confirmation)

- No false `DONE` for pre-existing zero-byte or partial files; no `DONE` after a failed decrypt.
- No silent corruption from a server that ignores `Range`; no `Content-Length` double count.
- No infinite retry loops; auth expiry is distinguishable from network failure.
- No lost audio when tagging fails; no deletion of an existing file before its replacement exists.
- No duplicate queue rows for the same track/destination/quality.
- "Clear finished/queue" never deletes music files.

### Known gaps

- Wi-Fi-only / charging-only / low-battery-pause rules, and automation for new likes/playlists/
  releases: not implemented.
- Home, Player, Search, Library redesigns: not in this change.

---

## [Unreleased]

### Added

- Phase One documentation set (documentation only, no application changes):
  - `PROJECT_AUDIT.md` — full repository audit: purpose, architecture, features/journeys, 19 ranked defects, UX/UI weaknesses, performance, security, recommendations, complexity/risk, method and verification limits.
  - `ARCHITECTURE.md` — runtime topology, module map, navigation/state/error/persistence analysis, coupling hot-spots, target architecture and decision log (A1–A10).
  - `FEATURES_INVENTORY.md` — per-feature status, screen inventory, settings inventory, journey friction points, feature gaps.
  - `BUGS_AND_TECHNICAL_DEBT.md` — defect register (BUG-01…BUG-21) and debt register (TD-01…TD-18).
  - `UPGRADE_ROADMAP.md` — milestones M0–M8 with acceptance criteria, risks, estimates and approval gates.
  - `DEVELOPMENT_STATUS.md` — phase status, blockers, verification performed.
  - `CHANGELOG.md` — this file.

### Changed

- Nothing in the application. No Dart, Java, Android resource, asset or translation files were modified.

### Known issues recorded (not yet fixed)

- P0: unauthenticated local stream server (`127.0.0.1:36958`) exposes offline audio to any local requester.
- P0/P1: Deezer ARL and Spotify credentials stored in plaintext `settings.json`.
- P1: corrupt `settings.json`/`metacache.json` prevents app startup (white screen).
- P1: search results never surface an error (infinite spinner); `late` locals crash on failed requests.
- P1: no HTTP timeouts; fixed stream-server port fails silently, breaking all playback.
- P2: dead "Visualizer" setting, player-bar rebuild loop, lyrics timer leak, non-virtualised lists, unverified self-update, "delete download" leaves the file on disk, i18n gaps (11 keys; two locales < 8 %).
- Process: no tests, no CI, no lockfile, uninitialised submodules, missing `.env`/`env.g.dart`.

See `BUGS_AND_TECHNICAL_DEBT.md` for evidence and fix plans.

---

## [0.7.15] — baseline (audited commit `2bb8009`, 2025-06-11)

Initial state at the start of this engagement, summarised from the repository history and README rather than from a changelog:

- Alternative Deezer client: streaming, downloads (external + private offline), tagged files, lyrics (synced/unsynced), Flow, library management, playlists, shows/episodes.
- Android Auto and Android TV/DPAD support, quick actions, selectable launcher icons, display-mode selection.
- 31 languages via Crowdin; four themes; Google Fonts; gradient/blurred player backgrounds.
- Native download service in a separate process with `jaudiotagger` tagging and AES/Blowfish decryption; NanoHTTPD loopback stream server for playback.
- Latest in-repo changes: app icon selection (two additional icons), a settings translation string, plus smaller fixes and formatting.

No test suite, CI configuration, or dependency lockfile existed at this baseline.
