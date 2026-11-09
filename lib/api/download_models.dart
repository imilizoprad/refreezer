// Pure data model for downloads.
//
// This file deliberately has **no Flutter imports** so the queue logic, state mapping and
// formatting can be unit tested without a widget binding. `lib/api/download.dart` re-exports it.

/// Mirrors `Download.DownloadState` in
/// `android/app/src/main/java/r/r/refreezer/Download.java`.
///
/// The order is the wire format (the native side sends the ordinal), so new values may only be
/// **appended** — PAUSED and CANCELLED were added after ERROR for exactly this reason.
enum DownloadState {
  NONE,
  DOWNLOADING,
  POST,
  DONE,
  DEEZER_ERROR,
  ERROR,
  PAUSED,
  CANCELLED,
}

/// Safe conversion from the native ordinal.
/// Coerces a numeric value that may arrive as `int`, `num` or `String` (older platform-channel
/// payloads sent numbers as strings). Returns `null` when the value is not numeric.
int? coerceToInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

DownloadState downloadStateFromIndex(dynamic index, {DownloadState fallback = DownloadState.NONE}) {
  final int? value = coerceToInt(index);
  if (value == null) return fallback;
  if (value < 0 || value >= DownloadState.values.length) return fallback;
  return DownloadState.values[value];
}

extension DownloadStateX on DownloadState {
  /// Waiting in the queue (may be waiting for its retry timer).
  bool get isQueued => this == DownloadState.NONE;

  /// Bytes are moving or the file is being processed.
  bool get isActive => this == DownloadState.DOWNLOADING || this == DownloadState.POST;

  bool get isDone => this == DownloadState.DONE;

  bool get isFailed => this == DownloadState.ERROR || this == DownloadState.DEEZER_ERROR;

  bool get isPaused => this == DownloadState.PAUSED;

  bool get isCancelled => this == DownloadState.CANCELLED;

  /// No worker is running and no automatic progress can happen.
  bool get isSettled => isDone || isFailed || isPaused || isCancelled;

  /// Short, human readable label.
  String get label {
    switch (this) {
      case DownloadState.NONE:
        return 'Queued';
      case DownloadState.DOWNLOADING:
        return 'Downloading';
      case DownloadState.POST:
        return 'Processing';
      case DownloadState.DONE:
        return 'Downloaded';
      case DownloadState.DEEZER_ERROR:
        return 'Unavailable';
      case DownloadState.ERROR:
        return 'Failed';
      case DownloadState.PAUSED:
        return 'Paused';
      case DownloadState.CANCELLED:
        return 'Cancelled';
    }
  }

  /// Ordering inside a queue list: work that can still move comes first.
  int get sortRank {
    switch (this) {
      case DownloadState.DOWNLOADING:
        return 0;
      case DownloadState.POST:
        return 1;
      case DownloadState.PAUSED:
        return 2;
      case DownloadState.NONE:
        return 3;
      case DownloadState.ERROR:
        return 4;
      case DownloadState.DEEZER_ERROR:
        return 5;
      case DownloadState.CANCELLED:
        return 6;
      case DownloadState.DONE:
        return 7;
    }
  }
}

/// Queue priority. Lower value wins, matching the native scheduler.
class DownloadPriority {
  final int value;
  final String label;

  const DownloadPriority._(this.value, this.label);

  static const DownloadPriority high = DownloadPriority._(0, 'High');
  static const DownloadPriority normal = DownloadPriority._(1, 'Normal');
  static const DownloadPriority low = DownloadPriority._(2, 'Low');

  static const List<DownloadPriority> values = [high, normal, low];

  static DownloadPriority fromValue(dynamic value) {
    final int? parsed = coerceToInt(value);
    if (parsed == null) return normal;
    for (DownloadPriority priority in values) {
      if (priority.value == parsed) return priority;
    }
    return normal;
  }
}

/// A single download, as stored by the native service.
class Download {
  int? id;
  String? path;
  bool? private;
  String? trackId;
  String? streamTrackId;
  String? trackToken;
  String? md5origin;
  String? mediaVersion;
  String? title;
  String? image;
  int? quality;

  // Persisted scheduling/diagnostics
  DownloadPriority priority;
  int attempts;
  int nextRetryAt;
  int createdAt;
  String? groupId;
  String? metadataWarning;
  String? errorKind;
  String? errorMessage;

  // Dynamic
  DownloadState state;
  int received;
  int filesize;
  int speed;

  Download({
    this.id,
    this.path,
    this.private,
    this.trackId,
    this.streamTrackId,
    this.trackToken,
    this.md5origin,
    this.mediaVersion,
    this.title,
    this.image,
    this.quality,
    this.priority = DownloadPriority.normal,
    this.attempts = 0,
    this.nextRetryAt = 0,
    this.createdAt = 0,
    this.groupId,
    this.metadataWarning,
    this.errorKind,
    this.errorMessage,
    this.state = DownloadState.NONE,
    this.received = 0,
    this.filesize = 0,
    this.speed = 0,
  });

  /// Progress between 0 and 1. Never divides by zero.
  double get progress {
    if (filesize <= 0) return 0;
    double value = received / filesize;
    if (value.isNaN) return 0;
    return value.clamp(0.0, 1.0).toDouble();
  }

  /// True when the download is waiting for an automatic retry.
  bool get awaitingRetry => state == DownloadState.NONE && nextRetryAt > 0;

  /// Seconds until the next automatic retry (null when not waiting).
  int? get retryInSeconds {
    if (!awaitingRetry) return null;
    int remaining = ((nextRetryAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return remaining < 0 ? 0 : remaining;
  }

  /// Estimated seconds remaining, only when a speed is known.
  int? get etaSeconds {
    if (state != DownloadState.DOWNLOADING || speed <= 0 || filesize <= 0) return null;
    int remaining = filesize - received;
    if (remaining <= 0) return 0;
    return (remaining / speed).ceil();
  }

  /// Identity used to detect duplicates: same track, destination, quality and visibility.
  String get dedupeKey => '${trackId ?? ''}|${path ?? ''}|${quality ?? 0}|${private == true ? 1 : 0}';

  /// Quality label used in the UI ('MP3 320' etc.), unknown when the service has not resolved it.
  String get qualityLabel {
    switch (quality) {
      case 1:
        return 'MP3 128';
      case 3:
        return 'MP3 320';
      case 9:
        return 'FLAC';
      default:
        return 'Auto';
    }
  }

  /// Human readable failure reason. Never exposes a raw exception to the user.
  String get errorText {
    switch (errorKind) {
      case 'network':
        return 'Network problem — it will retry automatically.';
      case 'timeout':
        return 'The connection timed out.';
      case 'server':
        return 'Deezer is busy right now.';
      case 'auth':
        return 'Your session expired. Sign in again to continue.';
      case 'storage':
        return 'Not enough free space to finish this download.';
      case 'permission':
        return 'Storage permission is missing.';
      case 'unavailable':
        return 'This track is not available for download.';
      case 'processing':
        return 'The file could not be decrypted. Retry to download it again.';
      case 'duplicate':
        return 'Already in the queue.';
      case 'cancelled':
        return 'You cancelled this download.';
      case 'interrupted':
        return 'Interrupted — it will resume.';
      case 'metadata':
        return 'Audio saved, but tags could not be written.';
      default:
        return 'Download failed.';
    }
  }

  factory Download.fromJson(Map<dynamic, dynamic> data) {
    return Download(
      path: data['path'],
      image: data['image'],
      private: data['private'],
      trackId: data['trackId'],
      streamTrackId: data['streamTrackId'],
      trackToken: data['trackToken'],
      md5origin: data['md5origin'],
      mediaVersion: data['mediaVersion'],
      id: coerceToInt(data['id']),
      state: downloadStateFromIndex(data['state']),
      title: data['title'],
      quality: coerceToInt(data['quality']),
      priority: DownloadPriority.fromValue(data['priority']),
      attempts: _toInt(data['attempts']),
      nextRetryAt: _toInt(data['nextRetryAt']),
      createdAt: _toInt(data['createdAt']),
      groupId: data['groupId'],
      errorKind: data['errorKind'],
      errorMessage: data['errorMessage'],
      metadataWarning: data['metadataWarning'],
      received: _toInt(data['received']),
      filesize: _toInt(data['filesize']),
    );
  }

  /// Merge a lightweight progress/state payload from the native service.
  void updateFromJson(Map<dynamic, dynamic> data) {
    if (data['state'] != null) state = downloadStateFromIndex(data['state'], fallback: state);
    if (data['quality'] != null) quality = coerceToInt(data['quality']);
    if (data.containsKey('received')) received = _toInt(data['received']);
    if (data.containsKey('filesize')) filesize = _toInt(data['filesize']);
    if (data.containsKey('speed')) speed = _toInt(data['speed']);
    if (data.containsKey('attempts')) attempts = _toInt(data['attempts']);
    if (data.containsKey('nextRetryAt')) nextRetryAt = _toInt(data['nextRetryAt']);
    if (data.containsKey('errorKind')) errorKind = data['errorKind'];
    if (data.containsKey('metadataWarning')) metadataWarning = data['metadataWarning'];
  }

  static int _toInt(dynamic value) => coerceToInt(value) ?? 0;
}

/// Result of enqueueing a batch of downloads.
class DownloadEnqueueResult {
  final int added;
  final int existing;
  final int requeued;

  const DownloadEnqueueResult({this.added = 0, this.existing = 0, this.requeued = 0});

  int get total => added + existing + requeued;

  factory DownloadEnqueueResult.fromJson(dynamic data) {
    if (data is Map) {
      return DownloadEnqueueResult(
        added: Download._toInt(data['added']),
        existing: Download._toInt(data['existing']),
        requeued: Download._toInt(data['requeued']),
      );
    }
    return const DownloadEnqueueResult();
  }
}

/// Aggregate view of the queue, used by the Downloads screen header.
class DownloadSummary {
  final int active;
  final int queued;
  final int paused;
  final int failed;
  final int completed;
  final int cancelled;
  final int total;
  final int downloadedBytes;
  final int totalBytes;

  const DownloadSummary({
    this.active = 0,
    this.queued = 0,
    this.paused = 0,
    this.failed = 0,
    this.completed = 0,
    this.cancelled = 0,
    this.total = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
  });

  bool get isIdle => active == 0 && queued == 0 && paused == 0 && failed == 0;

  bool get hasHistory => completed > 0 || cancelled > 0 || failed > 0;

  double get overallProgress {
    if (totalBytes <= 0) return 0;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  factory DownloadSummary.from(List<Download> downloads) {
    int active = 0, queued = 0, paused = 0, failed = 0, completed = 0, cancelled = 0;
    int downloadedBytes = 0, totalBytes = 0;
    for (Download download in downloads) {
      switch (download.state) {
        case DownloadState.DOWNLOADING:
        case DownloadState.POST:
          active++;
          break;
        case DownloadState.NONE:
          queued++;
          break;
        case DownloadState.PAUSED:
          paused++;
          break;
        case DownloadState.ERROR:
        case DownloadState.DEEZER_ERROR:
          failed++;
          break;
        case DownloadState.DONE:
          completed++;
          break;
        case DownloadState.CANCELLED:
          cancelled++;
          break;
      }
      if (download.bytesTotalOrSize > 0) {
        totalBytes += download.bytesTotalOrSize;
        downloadedBytes += download.received.clamp(0, download.bytesTotalOrSize).toInt();
      }
    }
    return DownloadSummary(
      active: active,
      queued: queued,
      paused: paused,
      failed: failed,
      completed: completed,
      cancelled: cancelled,
      total: downloads.length,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
    );
  }
}

extension DownloadBytes on Download {
  /// `filesize` while transferring, persisted size otherwise.
  int get bytesTotalOrSize => filesize > 0 ? filesize : 0;
}

/// The filters offered by the Downloads screen.
enum DownloadFilter {
  all,
  active,
  queued,
  completedDownload,
  failed,
  paused,
  history,
}

extension DownloadFilterX on DownloadFilter {
  String get label {
    switch (this) {
      case DownloadFilter.all:
        return 'All';
      case DownloadFilter.active:
        return 'Active';
      case DownloadFilter.queued:
        return 'Queued';
      case DownloadFilter.completedDownload:
        return 'Downloaded';
      case DownloadFilter.failed:
        return 'Failed';
      case DownloadFilter.paused:
        return 'Paused';
      case DownloadFilter.history:
        return 'History';
    }
  }

  bool matches(Download download) {
    switch (this) {
      case DownloadFilter.all:
        return true;
      case DownloadFilter.active:
        return download.state.isActive;
      case DownloadFilter.queued:
        return download.state.isQueued;
      case DownloadFilter.completedDownload:
        return download.state.isDone;
      case DownloadFilter.failed:
        return download.state.isFailed;
      case DownloadFilter.paused:
        return download.state.isPaused;
      case DownloadFilter.history:
        return download.state.isDone ||
            download.state.isFailed ||
            download.state.isCancelled;
    }
  }
}

/// Sort order for the list: active work first, then queue order, then history.
int compareDownloads(Download a, Download b) {
  int byState = a.state.sortRank.compareTo(b.state.sortRank);
  if (byState != 0) return byState;
  int byPriority = a.priority.value.compareTo(b.priority.value);
  if (byPriority != 0) return byPriority;
  int byCreated = a.createdAt.compareTo(b.createdAt);
  if (byCreated != 0) return byCreated;
  return (a.id ?? 0).compareTo(b.id ?? 0);
}

/// Case-insensitive match over title and artist-ish title field.
bool downloadMatchesQuery(Download download, String query) {
  if (query.trim().isEmpty) return true;
  String needle = query.toLowerCase().trim();
  String title = (download.title ?? '').toLowerCase();
  return title.contains(needle);
}

/// Conservative estimate of the bytes still needed for [downloads].
///
/// Unknown sizes use [defaultTrackBytes] so the UI can warn before a queue fills the device.
/// Returns -1 when nothing is pending.
int estimateRemainingBytes(
  Iterable<Download> downloads, {
  int defaultTrackBytes = 8 * 1024 * 1024,
}) {
  int total = 0;
  bool any = false;
  for (Download download in downloads) {
    if (!(download.state.isActive ||
        download.state.isQueued ||
        download.state.isPaused)) {
      continue;
    }
    any = true;
    int expected = download.filesize > 0 ? download.filesize : defaultTrackBytes;
    int remaining = expected - download.received;
    total += remaining < 0 ? 0 : remaining;
  }
  return any ? total : -1;
}

/// Bytes without depending on a formatting package (keeps this file testable).
String formatBytes(num bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const List<String> units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  String digits = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(decimals);
  // 1024.0 -> 1.0 MB reads better without the trailing ".0"
  if (digits.endsWith('.0')) digits = digits.substring(0, digits.length - 2);
  return '$digits ${units[unit]}';
}

/// Seconds as '1:05' / '2:10:00'.
String formatDuration(int seconds) {
  if (seconds < 0) seconds = 0;
  int hours = seconds ~/ 3600;
  int minutes = (seconds % 3600) ~/ 60;
  int secs = seconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${two(minutes)}:${two(secs)}';
  return '$minutes:${two(secs)}';
}
