import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/download.dart';

/// Single source of truth for the download UI.
///
/// The native service remains the owner of the queue; this controller mirrors it, merges the
/// high-frequency progress events and exposes stable, sorted lists plus the actions the UI needs.
/// Screens never talk to the platform channel directly.
class DownloadController extends ChangeNotifier {
  DownloadController._();

  static final DownloadController instance = DownloadController._();

  final List<Download> _downloads = [];
  List<Download> get downloads => List<Download>.unmodifiable(_downloads);

  DownloadSummary summary = const DownloadSummary();
  bool running = false;
  bool loaded = false;
  bool loading = false;
  String? loadError;
  String? blockReason;
  int freeBytes = -1;

  StreamSubscription? _subscription;
  Timer? _refreshTimer;
  Timer? _notifyTimer;
  bool _refreshing = false;
  bool _refreshPending = false;
  DateTime? _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isBusy => summary.active > 0;

  bool get hasWork => summary.active > 0 || summary.queued > 0 || summary.paused > 0;

  bool get needsAuth => blockReason == 'auth';

  /// Attach to the native event stream once.
  Future<void> attach() async {
    if (_subscription != null) return;
    _subscription = downloadManager.serviceEvents.stream.listen(_onEvent);
    await refresh();
  }

  void detach() {
    _subscription?.cancel();
    _subscription = null;
    _refreshTimer?.cancel();
    _notifyTimer?.cancel();
  }

  // --- data ---------------------------------------------------------------------------------

  Future<void> refresh() async {
    if (_refreshing) {
      _refreshPending = true;
      return;
    }
    _refreshing = true;
    loading = _downloads.isEmpty;
    notifyListeners();
    try {
      List<Download> fresh = await downloadManager.getDownloads();
      fresh.sort(compareDownloads);
      _downloads
        ..clear()
        ..addAll(fresh);
      summary = DownloadSummary.from(_downloads);
      running = downloadManager.running;
      blockReason = downloadManager.blockReason;
      loadError = null;
      loaded = true;
    } catch (e) {
      // Never hide a failure behind an empty list.
      loadError = 'Could not read the download queue.';
      loaded = _downloads.isNotEmpty;
    } finally {
      _refreshing = false;
      loading = false;
      notifyListeners();
      if (_refreshPending) {
        _refreshPending = false;
        scheduleRefresh(delay: const Duration(milliseconds: 400));
      }
    }
  }

  /// Coalesce refresh bursts (a batch finishing fires several state changes).
  void scheduleRefresh({Duration delay = const Duration(milliseconds: 250)}) {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(delay, refresh);
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final String? action = event['action']?.toString();

    if (action == 'onProgress') {
      final dynamic data = event['data'];
      if (data is List) {
        bool changed = false;
        for (dynamic raw in data) {
          if (raw is! Map) continue;
          final dynamic rawId = raw['id'];
          if (rawId is! int) continue;
          for (Download download in _downloads) {
            if (download.id == rawId) {
              int previousReceived = download.received;
              DownloadState previousState = download.state;
              download.updateFromJson(raw);
              if (previousReceived != download.received || previousState != download.state) {
                changed = true;
              }
              break;
            }
          }
        }
        if (changed) {
          summary = DownloadSummary.from(_downloads);
          _notifyThrottled();
        }
      }
      return;
    }

    if (action == 'onStateChange') {
      running = event['running'] == true;
      blockReason = event['blockReason'] as String?;
      scheduleRefresh();
      _notifyThrottled(force: true);
    }
  }

  void _notifyThrottled({bool force = false}) {
    final DateTime now = DateTime.now();
    if (force || now.difference(_lastNotify) > const Duration(milliseconds: 200)) {
      _lastNotify = now;
      notifyListeners();
      return;
    }
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 200), notifyListeners);
  }

  // --- derived lists ------------------------------------------------------------------------

  List<Download> filtered({
    DownloadFilter filter = DownloadFilter.all,
    String query = '',
    DownloadPriority? priority,
  }) {
    List<Download> out = _downloads
        .where((d) => filter.matches(d))
        .where((d) => downloadMatchesQuery(d, query))
        .where((d) => priority == null || d.priority == priority)
        .toList();
    out.sort(compareDownloads);
    return out;
  }

  /// Active first, then the queue in scheduler order, then history.
  Map<String, List<Download>> grouped() {
    List<Download> history = _downloads
        .where((d) => d.state.isDone || d.state.isCancelled)
        .toList();
    // Newest first inside the history section.
    history.sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
    return {
      'active': _downloads.where((d) => d.state.isActive).toList(),
      'waiting': _downloads.where((d) => d.state.isQueued || d.state.isPaused).toList(),
      'failed': _downloads.where((d) => d.state.isFailed).toList(),
      'finished': history,
    };
  }

  Download? byId(int? id) {
    if (id == null) return null;
    for (Download download in _downloads) {
      if (download.id == id) return download;
    }
    return null;
  }

  // --- storage ------------------------------------------------------------------------------

  Future<void> refreshStorage() async {
    freeBytes = await downloadManager.freeDiskSpaceBytes();
    notifyListeners();
  }

  /// Rough estimate of the space the remaining queue needs. Returns -1 when nothing is queued.
  int estimatedRemainingBytes() => estimateRemainingBytes(_downloads);

  // --- actions ------------------------------------------------------------------------------

  Future<void> startQueue() async {
    await downloadManager.resumeAll();
    _markRunning(true);
  }

  Future<void> pauseQueue() async {
    await downloadManager.pauseAll();
    _markRunning(false);
  }

  Future<void> pause(Download download) async {
    if (download.id == null) return;
    await downloadManager.pauseDownload(download.id!);
    download.state = DownloadState.PAUSED;
    summary = DownloadSummary.from(_downloads);
    notifyListeners();
    scheduleRefresh();
  }

  Future<void> resume(Download download) async {
    if (download.id == null) return;
    await downloadManager.resumeDownload(download.id!);
    download.state = DownloadState.NONE;
    summary = DownloadSummary.from(_downloads);
    notifyListeners();
    scheduleRefresh();
  }

  Future<void> cancel(Download download) async {
    if (download.id == null) return;
    await downloadManager.cancelDownload(download.id!);
    download.state = DownloadState.CANCELLED;
    summary = DownloadSummary.from(_downloads);
    notifyListeners();
    scheduleRefresh();
  }

  Future<void> retry(Download download) async {
    if (download.id == null) return;
    await downloadManager.retryDownload(download.id!);
    download
      ..state = DownloadState.NONE
      ..attempts = 0
      ..nextRetryAt = 0
      ..errorKind = null;
    summary = DownloadSummary.from(_downloads);
    notifyListeners();
    scheduleRefresh();
  }

  Future<void> retryAllFailed() async {
    await downloadManager.retryDownloads();
    scheduleRefresh();
  }

  Future<void> setPriority(Download download, DownloadPriority priority) async {
    if (download.id == null) return;
    await downloadManager.setPriority(download.id!, priority);
    download.priority = priority;
    notifyListeners();
    scheduleRefresh();
  }

  /// Move [download] to the front of the queue.
  Future<void> moveToFront(Download download) async {
    if (download.id == null) return;
    await downloadManager.moveDownload(download.id!);
    scheduleRefresh();
  }

  /// Remove one entry. [deleteFile] is false everywhere by default so history cleanup never
  /// deletes music.
  Future<void> remove(Download download, {bool deleteFile = false}) async {
    if (download.id == null) return;
    await downloadManager.removeDownload(download.id!, deleteFile: deleteFile);
    _downloads.removeWhere((d) => d.id == download.id);
    summary = DownloadSummary.from(_downloads);
    notifyListeners();
    scheduleRefresh();
  }

  /// Clear history for a state (downloads/cancelled) without touching the files.
  Future<void> clearHistory(DownloadState state) async {
    await downloadManager.removeDownloads(state);
    _downloads.removeWhere((d) => d.state == state);
    summary = DownloadSummary.from(_downloads);
    notifyListeners();
    scheduleRefresh();
  }

  void _markRunning(bool value) {
    running = value;
    notifyListeners();
  }
}
