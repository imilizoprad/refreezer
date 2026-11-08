# Downloader Upgrade + Premium UI/UX — Delivery Report

**Date:** 2026-11-08 · **Branch:** `arena/f4b6f150-refreezer` (base `2bb8009`, audit `fc21d87`)
**Scope delivered:** downloader engine (Parts 3–4/6), queue management, database migration, design
system and a rebuilt Downloads screen (Part 5), tests, documentation.

> **Verification honesty:** this environment has no Flutter/Dart/JDK/Android SDK and no device.
> Everything below marked **UNVERIFIED** is implemented and statically checked only. Nothing is
> marked "tested" that was not actually executed. See §9 for exactly what ran.

---

## 1. Implemented / tested / unverified

| Bucket | Contents |
|---|---|
| **Implemented** | Native engine rewrite (state model, scheduling, retries, resume validation, safe finalisation, temp lifecycle, notifications, restart recovery), DB v2 additive migration, duplicate prevention, queue controls, Dart model + controller + API, design tokens/components, rebuilt Downloads screen, Settings controls for retries/notifications |
| **Tested (executed here)** | Dart syntax parse of all 55 `lib/` + `test/` files (tree-sitter); Java parse of all 13 files (javalang); grep-level review of every call site touched. **No unit tests, no build, no device run.** |
| **Unverified** | Everything runtime: `javac`/Kotlin compile, Gradle, `dart analyze`, `flutter test`, playback, downloads, decryption, tagging, resume after kill, notifications, permissions, Android Auto/TV, RTL, accessibility, performance |

Unit tests are **written but not executed** (§7).

---

## 2. Downloader architecture changes

### Before (baseline defects)

- Queue order = database/array order; no priority, no reordering.
- `stop()` marked active jobs `NONE` (indistinguishable from never started); the service also
  stopped itself on *every* finished track.
- Cross-thread queue mutation through an `updateRequests`/`updating` re-entrancy loop, with a
  `beginTransaction()` that survived exceptions.
- `Range` resume appended blindly; a server answering `200` (or a wrong offset) silently produced a
  corrupt file; `filesize = start + contentLength` double counted.
- Any existing file → `DONE` (including zero-byte or half-written ones); post-decrypt existence check
  also marked `DONE`.
- No retries at all; no status classification; no read timeout; cover downloads had no timeouts.
- Tagging failures swallowed after the file was already moved into place.
- Zero duplicate prevention; orphan `.ENC` files never cleaned; one notification per active track.

### After

```
enqueue (dedupe: track + path + quality + privacy)
   ↓
DB v2 row (state=NONE, priority, createdAt, attempts, nextRetryAt)
   ↓  scheduler (priority → createdAt → id; 1..8 slots; auth gate)
DOWNLOADING ──▶ [resolve stream] ──▶ [validated Range download to cache/<id>.part]
   │                                        │ (network, timeout, server, storage…)
   │                                        ▼
   │                              classified failure → attempts++ → backoff (jitter, Retry-After)
   │                                        └── permanent → ERROR / DEEZER_ERROR + reason
   ▼
POST ──▶ decrypt (failure ⇒ processing error, temp kept) ──▶ size validation
   ──▶ staging file in destination dir ──▶ atomic rename ──▶ cover/lyrics/tags
                                          │                      └── failure ⇒ DONE + metadataWarning
                                          ▼
                                        DONE (only with a validated file at the destination)
```

**State machine** (native ordinals preserved, two values appended):

| Value | State | Meaning | Terminal |
|---|---|---|---|
| 0 | `NONE` | queued (may be counting down to a retry) | no |
| 1 | `DOWNLOADING` | bytes transferring | no |
| 2 | `POST` | decrypt/tag/finalise | no |
| 3 | `DONE` | validated file saved | yes |
| 4 | `DEEZER_ERROR` | not available for download | yes |
| 5 | `ERROR` | transfer/IO/auth failure | yes |
| 6 | `PAUSED` | user paused, resumable | yes (until resumed) |
| 7 | `CANCELLED` | user cancelled, resumable via retry | yes |

Legacy behaviour preserved deliberately: `MainActivity` still treats `state >= 3` as "finished", which
remains true for every appended value.

---

## 3. Reliability work (each item maps to a baseline defect)

| Defect | Fix |
|---|---|
| False `DONE` for pre-existing/empty files | Existing file counts only if ≥ 16 KB; otherwise the job proceeds and the file is replaced **after** the new one is validated |
| Corrupt resume | `Range` only when a partial exists; append **only** on `206`; `200`/`416` truncate and restart; final length compared with `Content-Length` |
| No retries | Backoff 3 s → 5 min, ±20 % jitter, `Retry-After`, `maxRetries` 0–10 (Settings), no retry for auth/unavailable/permission |
| Auth ≈ network | `auth` classification (missing/invalid ARL) surfaces “Sign in again” and the queue is retained (`blockReason=auth`) |
| Storage exhaustion | `ENOSPC`/IO classified as `storage`, retried a bounded number of times; low-space warning in the UI before it happens |
| Tagging failure | Audio is kept; job completes with `metadataWarning`; UI says “Audio saved, tags incomplete” |
| Temp file orphans | `.part`/`.part.DEC` lifecycle, legacy `.ENC` migration, purge at service start, delete on cancel |
| Lost queue on process death | `running` flag persisted; busy rows recovered to `NONE` with `errorKind=interrupted`; partial files resumed |
| Service shutting down mid-queue | `stopSelf()` removed from per-track paths; the service stops only when the queue is idle |
| Race conditions | Single-threaded queue/DB ownership; worker → main-thread transitions; no nested transactions |
| Duplicate downloads | Dedupe on track + destination + quality + privacy at insert, on load and via `{added, existing, requeued}` |
| “Clear queue” deleting music | History removal deletes rows only; deleting a file is a separate, confirmed, explicit action |
| Notification spam | One aggregate notification + opt-in per-track; results channel; permission-checked |

---

## 4. Performance

**What changed structurally (not measured):**

- Progress events: one 500 ms tick for the whole queue instead of per-thread notification churn, and
  the notification is `setOnlyAlertOnce`/silent.
- The scheduler no longer scans and rebuilds the thread list on every message; `updateQueue()` runs
  on the main thread only, so there is no lock-hopping between workers.
- Dart: progress merges are throttled to ≤ 5 Hz and list refreshes are coalesced (250 ms), so a burst
  of completions causes one platform round-trip instead of one per event.
- The Downloads screen is a single `ListView` with grouped children (no nested scrollables), rows are
  `const` where possible, and artwork is loaded through `CachedNetworkImage`.

**Not measured:** no before/after timings, no memory or frame-time numbers. The environment cannot
build or run the app, so any figure would be invented. Measurement plan: profile a 50-track album
download (`flutter run --profile`) and compare frame times while the queue is active, plus
`dumpsys batterystats` for wakeups.

---

## 5. Database changes & migration strategy

**Schema v2 columns (all additive, all nullable/defaulted):**
`priority INTEGER DEFAULT 1`, `attempts INTEGER DEFAULT 0`, `nextRetryAt INTEGER DEFAULT 0`,
`errorKind TEXT`, `errorMessage TEXT`, `bytesTotal INTEGER DEFAULT 0`, `createdAt INTEGER DEFAULT 0`,
`groupId TEXT`, `metadataWarning TEXT`.

**Strategy**
1. `DATABASE_VERSION = 2`; `onUpgrade(1→2)` runs `ALTER TABLE … ADD COLUMN` per missing column inside
   `try/catch`, so one failure cannot abort the rest.
2. `ensureColumns()` runs on **every open** (idempotent, `PRAGMA table_info` first). A database that
   was only partially migrated — or a row inserted by an older build — self-heals.
3Completed rows get `createdAt = id` so queue ordering is stable after the migration.
4. **No `DROP TABLE`, no `DELETE`** in the migration. `onDowngrade` is a no-op that logs: older builds
   ignore unknown columns and keep working.
5. Reads use **named columns with defaults** (`Download.fromSQL`), so a v1 database opened by v2 code
   (or vice versa) never crashes on a missing column.

**Rollback:** installing an older build keeps all rows; new columns are ignored. No irreversible step.

---

## 6. Preserved functionality (explicitly checked)

- Java `DownloadService` opcodes 1–9 unchanged in value and meaning; the new opcodes are 10–15.
- Message names `SERVICE_*` and the event channel `r.r.refreezer/downloads` unchanged; event payloads
  are **extended**, never renamed (`onProgress` gains `speed`, `onStateChange` gains counters and
  `blockReason`).
- `DownloadSettings.fromBundle` keeps every previous key, tolerates missing ones (defaults instead of
  `null` → no more NPE) and accepts the two new ones.
- Decryption (`DeezerDecryptor`), tagging (`Deezer.tagTrack`), LRC generation, cover/album-cover,
  `.nomedia`, media-scanner broadcast, quality fallback, user-upload filename rules: unchanged logic,
  same call order.
- Offline layout on disk is unchanged (`%artist% - %title%`, album/artist/playlist folders, album art
  resolution); previously downloaded files remain valid and are recognised as already downloaded.
- `audio_service`/`just_audio`, `_aa_` Android Auto ids, Deezer contracts, auth, library tables: not
  touched.
- Settings JSON stays backward/forward compatible; new keys are optional.

---

## 7. Tests

**Written (in `test/`, not executed — no Dart/Flutter available):**

- `test/download_models_test.dart` — wire ordinals (including the PAUSED/CANCELLED append-only rule),
  malformed ordinal fallbacks, JSON tolerance (numeric strings, missing counters), progress bounds,
  progress-merge preserving persisted fields, human failure copy for every kind, auth≠network copy,
  retry countdown, dedupe identity (path/quality/privacy/title independence), ETA rules.
- `test/download_queue_test.dart` — total ordering (active → queue → failed → history; priority →
  createdAt → id), filter semantics incl. history, search normalisation, summary counts/progress,
  storage estimation (known/unknown/over-downloaded/empty), byte and duration formatting.

**Run with** `flutter test` once a toolchain exists. Expected: all pass; anything failing is a real
signal, not a flake (no clock/network dependency except two retry tests that use `DateTime.now()`
with tolerant bounds).

**Not covered by automated tests:** the Java engine (no JVM here). The intended follow-up is
instrumentation tests for the queue state machine plus a fake HTTP server for resume/retry.

---

## 8. Architectural decisions (with trade-offs)

| ID | Decision | Why | Cost |
|---|---|---|---|
| D-01 | Keep the Java downloader; rewrite its internals in place | Preserves the native protocol, decryption and file layout; no Dart rewrite risk | The service file is large (~2 000 lines) and would benefit from extraction later |
| D-02 | Append-only state enum | Persisted ordinals and `state >= 3` semantics in `MainActivity` stay valid | Enum order is now a compatibility constraint (documented in both languages) |
| D-03 | Main-thread queue ownership | Removes the re-entrancy races without introducing locks | DB writes are on the UI thread (small rows, batched by transitions) |
| D-04 | Staging file + atomic rename in the destination folder | A crash can never leave a truncated track at the final path | Needs free space for one extra copy during finalisation |
| D-05 | Metadata failures are a warning, not a failure | The user keeps playable audio | Requires a new field/state nuance in the UI |
| D-06 | Retries via `nextRetryAt` + the existing 500 ms tick | No new timers, no `AlarmManager`, survives process death | Retry precision is 500 ms |
| D-07 | `DownloadController` as the UI's only data source | One subscription, one sort order, testable model | Screens must migrate to it over time |
| D-08 | Design tokens derived from the current `ThemeData` | No global theme migration, user accent colour respected, zero risk to other screens | New screens must opt in explicitly |
| D-09 | Settings fields added by hand to `settings.g.dart` | `build_runner` is unavailable; keeps generated code in sync | Must re-run `build_runner` later and drop the manual edit if it differs |

---

## 9. Verification actually performed

| Command | Result |
|---|---|
| `python /tmp/dartgram/parse.py $(find lib test -name '*.dart')` | 55 files parsed, **3 errors — all pre-existing** (`refreezer_icons.dart:16`, `app_icon_changer.dart:19`, `version.dart:28`) |
| `python /tmp/parsejava.py $(find android -name '*.java')` | 13 files, **0 errors** |
| `flutter analyze` / `dart format` / `flutter test` / `flutter build apk` | **not run** — toolchain unavailable |
| Device/emulator | **none** |

---

## 10. Known limitations & remaining bugs

1. **No build or runtime verification** — the single biggest caveat of this change.
2. Wi-Fi-only / charging-only / low-battery-pause download rules and “automatically download new
   likes / playlist tracks / releases”: **not implemented**.
3. Collection-aware “skip already offline” *pre-filter* (before enqueueing a whole album/playlist):
   duplicate identity prevents double downloads, but the UI does not yet show “12 of 14 already
   offline”.
4. Redesign scope: Downloads screen only; Home, Player, Search, Library still use legacy widgets.
5. Undo exists for cancelling; removing entries/history is confirmation-only (the row is deleted).
6. Tagging runs on the final file (audio bytes are complete); a crash mid-tag can leave partial tags.
7. User-uploaded (negative id) tracks still cannot be downloaded; they now fail with a clear
   “not available” message.
8. TV/DPAD focus order, RTL, large-font and screen-reader behaviour on the new screen are unverified.
9. **No foreground service**: a queue running while the app is backgrounded can still be killed by
   the OS (unchanged from baseline). The service now shuts down when idle and unbound, but a long
   download in the background is not protected. Converting it to a `dataSync` foreground service
   (which can reuse the summary notification) needs manifest/permission changes that cannot be
   verified here — recommended as the next reliability step.
10. `DownloadService.java` remains a large class; extraction (queue/notifications/worker) is worth doing
   once tests can run.

---

## 11. Files changed

**Native (4 modified):**
`Download.java` (+285), `DownloadService.java` (rewritten, ~2 021), `DownloadsDatabase.java` (v2),
`MainActivity.java` (new channel methods, richer events, dedupe-aware enqueue).

**Dart (new 5 / modified 5):**
`lib/api/download_models.dart` (new, 521), `lib/service/download_controller.dart` (new, 293),
`lib/ui/design/tokens.dart` (new), `lib/ui/design/components.dart` (new),
`lib/ui/downloads_screen.dart` (rebuilt, 1 087), `lib/api/download.dart`,
`lib/settings.dart`, `lib/settings.g.dart`, `lib/ui/settings_screen.dart`.

**Tests (new 2):** `test/download_models_test.dart`, `test/download_queue_test.dart`.

**Docs:** `DEVELOPMENT_STATUS.md`, `CHANGELOG.md`, this report.

---

## 12. Build & install

```bash
# prerequisites: Flutter 3.32.x, JDK 17, Android SDK 35, NDK 27.0.12077973
git submodule update --init --recursive          # 5 path dependencies
cp lib/.env.example lib/.env                     # owner supplies Deezer / Last.fm keys
dart run build_runner build                      # regenerates settings.g.dart + env.g.dart
flutter pub get
flutter analyze
flutter test                                     # runs the two new test files
flutter build apk --debug
```

Instrumented/db checks: install over a v0.7.15 build with existing downloads and confirm the queue
list, completed history and offline files survive the schema v2 migration.

---

## 13. Before/after screenshots

None. Capturing them requires running the app; the previous Downloads screen is available at
`git show fc21d87:lib/ui/downloads_screen.dart` for a side-by-side once a toolchain exists.

---

## 14. Special attention for reviewers

1. **State enum order is now a contract** (`PAUSED=6`, `CANCELLED=7`). Never insert in the middle.
2. **`MIN_VALID_AUDIO_BYTES = 16 KB`** is a heuristic; very short tracks/ringtones below it would be
   rejected. Verify with a < 4 s track before release.
3. **Tagging after rename** is the residual crash window (§10.6).
4. **`settings.g.dart` was edited by hand** — re-run `build_runner` and diff it.
5. **`maxRetries`/`notifications` keys** are mapped in `Settings.getServiceSettings()`; renaming either
   side silently falls back to defaults.
6. **`MOVE_DOWNLOAD` reorders by rewriting `createdAt`** (target − 1 / − 1000). Repeated moves drift
   into negative values, which is fine, but do not sort on `createdAt` assuming human-readable times.
7. **The 700-line `DownloadSettings`/`SelectedTags` block** is unchanged in behaviour; it now returns
   defaults instead of `null`, so `settings != null` checks are obsolete but harmless.
