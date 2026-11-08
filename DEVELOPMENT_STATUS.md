# ReFreezer — Development Status

**Branch:** `arena/f4b6f150-refreezer` (from `master` @ `2bb8009`, audit commit `fc21d87`)
**Last updated:** 2026-11-08
**Current phase:** Downloader upgrade + Premium UI/UX execution — **engine (Parts 3–6) and Downloads UI (Part 5) implemented; runtime verification BLOCKED** (see §4)

Status labels: **DONE** (verified) · **IN PROGRESS** · **BLOCKED** (needs input/environment) · **UNVERIFIED** (implemented, not adequately tested).

---

## 1. Phase status (from the master execution prompt, Part 7)

| Phase | Scope | Status |
|---|---|---|
| 0 — Inspect & baseline | Re-read the native downloader, Dart layer, DB schema, channel protocol; baseline the syntax harness | **DONE** |
| 1 — Foundation | State model (append-only), DB v2 migration, `Download` model, `DownloadController`, design tokens | **DONE (static) / UNVERIFIED (runtime)** |
| 2 — Downloader reliability & speed | Safe finalisation, validated resume, retry classification + backoff, auth/storage/unavailable separation, temp-file lifecycle, orphan cleanup, idle-only service shutdown | **DONE (static) / UNVERIFIED (runtime)** |
| 3 — Queue & management | Priority, ordering/move-to-front, pause/resume per job and queue-wide, cancel, retry one/all, history cleanup without file deletion, duplicate prevention | **DONE (static) / UNVERIFIED (runtime)** |
| 4 — Design system | Tokens (obsidian/editorial), typography scale, progress rule, status, buttons, empty/error/loading states, sheets, filter bar, search field; reduced-motion support | **DONE** |
| 5 — Full UI/UX | Downloads screen rebuilt; Settings: retry + notification controls | **IN PROGRESS** — Downloads is the redesigned screen; Home/Player/Search/Library redesigns are **not** part of this pass |
| 6 — Intelligent downloads | Notification policy (all/summary/none), priority/queue automation | **PARTIAL / UNVERIFIED** — Wi-Fi-only, charging-only, low-battery pause and "new likes / new releases" automation are **not implemented** (see §5) |
| 7 — Polish & regression | Syntax verification, unit tests written, documentation | **IN PROGRESS** — tests written but **not executed** (no Dart/Flutter here) |

---

## 2. What changed

### Native engine (`android/app/src/main/java/r/r/refreezer/`)

| Area | Change | Status |
|---|---|---|
| DB schema | `DownloadsDatabase` v2: additive columns (`priority`, `attempts`, `nextRetryAt`, `errorKind`, `errorMessage`, `bytesTotal`, `createdAt`, `groupId`, `metadataWarning`); real `onUpgrade` + idempotent `ensureColumns()` self-heal on open; **no table is dropped and no user data is discarded**; downgrade is a no-op that preserves rows | DONE / UNVERIFIED |
| State model | `DownloadState` extended with `PAUSED(6)` / `CANCELLED(7)` **appended after `ERROR(5)`** so persisted ordinals and the `>= 3` "finished" test used by `MainActivity` keep their meaning | DONE |
| Concurrency | Queue, DB and all transitions now run on the main thread; worker threads report through `postState`/`postFailure`; the `updateRequests`/`updating` re-entrancy hack is gone; every DB write is wrapped (no dangling transactions) | DONE / UNVERIFIED |
| Scheduling | Ordered by `priority ASC, createdAt ASC, id ASC`; concurrency clamped to 1–8; start is refused while no ARL is configured (`blockReason=auth`) instead of failing every entry | DONE / UNVERIFIED |
| Resume correctness | `Range` resume only accepted on HTTP 206; a 200 response truncates and restarts instead of appending at the wrong offset; `416` restarts from zero; `Content-Length` no longer double-counts on 206; short/incomplete transfers are rejected and kept for the next attempt | DONE / UNVERIFIED |
| Retries | Failure classification (`network`, `timeout`, `server`, `auth`, `storage`, `permission`, `unavailable`, `processing`, `unknown`), bounded exponential backoff with ±20 % jitter (3 s → 5 min cap), `Retry-After` honoured, per-job retry budget from settings (`maxRetries`, 0 = off), permanent failures never retried | DONE / UNVERIFIED |
| Finalisation | Download → decrypt → validate size → staging file **in the destination folder** → atomic rename → tags. A job is `DONE` only when a non-empty, expected-size file exists at the destination. A pre-existing good file is never overwritten unless the user enabled overwriting, and never deleted before the replacement is validated | DONE / UNVERIFIED |
| Decryption | Failure is a first-class `processing` error (retryable), the encrypted temp file is kept, and the decrypt key now follows the stream that was actually downloaded (Deezer fallback-safe) | DONE / UNVERIFIED |
| Metadata isolation | Cover/lyrics/tag failures no longer fail the download: the audio is kept and the job completes with `metadataWarning` (`cover`, `tags`, `albumArt`) | DONE / UNVERIFIED |
| Temp lifecycle | `<id>.part`(+`.DEC`) replaces `<id>.ENC`, legacy files are migrated; temps deleted on cancel/remove; orphan temps purged at service start; `stopSelf()` no longer fires on every finished track — the service stops only when the queue is idle **and** no UI is bound, so an idle app does not keep a 500 ms loop alive | DONE / UNVERIFIED |
| Pause/cancel | `SERVICE_PAUSE_DOWNLOAD`, `RESUME_DOWNLOAD`, `CANCEL_DOWNLOAD`, `RETRY_DOWNLOAD`, `SET_PRIORITY`, `MOVE_DOWNLOAD` added; blocking reads are disconnected on pause/cancel so the action is immediate; queue-wide pause keeps the queue and partial files | DONE / UNVERIFIED |
| Duplicates | Identity is track + destination + quality + privacy; enqueue returns `{added, existing, requeued}`; load-time duplicates are cancelled instead of downloading twice; failed/cancelled requests re-queue instead of inserting a second row | DONE / UNVERIFIED |
| Notifications | Two channels (progress `IMPORTANCE_MIN`, results `IMPORTANCE_LOW`); one aggregate queue notification instead of one per track; per-track results opt-in (`all`), queue summary always, final "Downloads finished" summary; permission-checked, never throws | DONE / UNVERIFIED |
| Restart recovery | `running` persisted in `SharedPreferences`; on sticky restart the queue resumes once settings arrive; rows left in `DOWNLOADING`/`POST` are recovered to `NONE` with `errorKind=interrupted` | DONE / UNVERIFIED |
| Media scanner | Broadcast still sent for public downloads, using the final destination path | DONE |

### Dart

| Area | Change | Status |
|---|---|---|
| Model | New `lib/api/download_models.dart` (Flutter-free): state mirror with append-only ordinals, priority, retry/ETA/speed, dedupe key, human failure copy, filters, ordering, summary, storage estimate, formatters | DONE / UNVERIFIED |
| API | `lib/api/download.dart` re-exports the model, adds pause/resume/cancel/retry/priority/move/enqueue/summary/free-space; `removeDownload(deleteFile:)`; state-change mirror fields; `downloadJsonFromTrack` (was `Download.jsonFromTrack`) | DONE / UNVERIFIED |
| Controller | `lib/service/download_controller.dart`: single source of truth, throttled progress merge, coalesced refresh, optimistic state changes with reload, storage estimate | DONE / UNVERIFIED |
| Design system | `lib/ui/design/tokens.dart` + `components.dart`: obsidian/editorial palette derived from the existing theme, type scale, 4-pt spacing, hairline rules, thin progress rule, status dots, buttons without gradients, empty/error/skeleton states, bottom sheets, filter bar, underline search, confirm dialog, reduced-motion aware | DONE |
| Downloads screen | Rebuilt: overview header (state headline, aggregate progress, free space vs. estimate, auth/low-storage notices), filters with counts, search, grouped sections (Downloading / Queue / Needs attention / Finished), per-row status/progress/ETA/speed, pause/resume/cancel/retry/move-to-front, priority sheet, swipe pause/cancel, batch selection bar, confirmations, undo for cancel, "remove entry vs. delete file" split, empty/loading/error states | DONE / UNVERIFIED |
| Settings | "Automatic retries" and "Download notifications" controls; settings model + generated JSON updated by hand (no `build_runner` available) and mapped to the native contract in `getServiceSettings()` | DONE / UNVERIFIED |

### Tests (written, **not executed**)

`test/download_models_test.dart`, `test/download_queue_test.dart` — ordinals/wire format, parsing tolerance, progress bounds, failure copy, retry timing, dedupe identity, ETA, ordering, filters, search, summary, storage estimation, formatting.

---

## 3. Verification actually performed

| Check | Tool | Result |
|---|---|---|
| Dart syntax, all `lib/**` + `test/**` | `tree_sitter` + locally compiled `tree-sitter-dart` grammar | 55 files parsed; **3 errors, all pre-existing** (`lib/fonts/refreezer_icons.dart:16`, `lib/utils/app_icon_changer.dart:19`, `lib/utils/version.dart:28`). No new syntax errors. |
| Java syntax, all `android/**/*.java` | `javalang` | 13 files, 0 parse errors |
| Semantic compile (`javac`/`dart analyze`) | — | **BLOCKED** — no JDK/Dart/Flutter |
| Unit tests | — | **BLOCKED** — no Dart/Flutter; tests are unrun |
| Runtime/device behaviour | — | **BLOCKED** — no emulator, no Deezer account |

What the syntax checks do **not** prove: type correctness, API availability against the pinned Flutter/AGP versions, Gradle/manifest validity, and any runtime behaviour (downloads, decryption, resume, notifications).

---

## 4. Blockers (unchanged)

| ID | Blocker | Impact |
|---|---|---|
| BLK-01 | No Flutter/Dart/Java/Android SDK; `pub.dev`, `storage.googleapis.com`, `services.gradle.org` unreachable | No analyse/test/build/emulator; API-level mistakes cannot be caught here |
| BLK-02 | 5 git submodules empty | Fresh clone cannot resolve path dependencies |
| BLK-03 | `lib/.env` / `lib/utils/env.g.dart` absent (git-ignored, owner credentials) | Compile error without owner-supplied keys |
| BLK-04 | No device / Deezer account | Download, decryption, tagging, permission, Android Auto/TV paths remain unverified |

---

## 5. Known limitations of this pass (explicitly not done)

1. **Wi-Fi-only / charging-only / low-battery-pause** download rules: not implemented (would need a `BroadcastReceiver`/`ConnectivityManager` gate; cannot be device-verified here).
2. **Automation for new likes / new playlist tracks / new artist releases**: not implemented.
3. **Collection-aware download rules** (skip already-offline inside an album/playlist batch): duplicate identity is enforced per track, but the UI does not yet pre-filter a whole collection before enqueueing.
4. **Redesign scope**: only the Downloads screen plus new design primitives. Home, Player, Search and Library are unchanged; they still use the legacy theme and widgets.
5. **Undo** exists for cancelling a download (resume). Removing an entry or clearing history is confirmation-only, because the row is deleted from the native DB.
6. **Tagging happens after final rename**: a crash during tagging could leave a partially tagged file (audio bytes intact). Tagging a staging file before rename was rejected because the tag writer may depend on the file extension; recorded as a residual risk.
7. **TV/DPAD focus order** on the new screen is untested; rows are plain `InkWell`s so focus traversal works, but it is unverified.
8. **RTL/long-text**: layouts use `Flexible`/`ellipsis` and no fixed-width text, but RTL was not visually verified.
9. **No foreground service**: a long queue running while the app is in the background can still be
   killed by the OS (same as before). Moving the queue to a `dataSync` foreground service is the
   recommended follow-up; it needs manifest changes that cannot be verified in this environment.
10. **User-uploaded (negative id) tracks** still cannot be downloaded; they now fail with `unavailable` and a clear message instead of a generic error.

---

## 6. Next steps

1. Provide the toolchain (or run on a workstation): `flutter pub get`, `dart format`, `flutter analyze`, `flutter test` (the new tests), then `flutter build apk --debug`.
2. Device pass: pause/resume/cancel, app kill during download (resume), expired ARL, full storage, airplane-mode retry/backoff, tag failure, duplicate enqueue, 200-vs-206 resume, notification policy.
3. Then: collection pre-filter ("skip already offline"), Wi-Fi/charging rules, and the remaining screens' redesign on top of `RfTokens`.
