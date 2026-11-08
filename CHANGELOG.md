# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

The project previously tracked changes through GitHub releases only; this file starts at the audited baseline.

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
