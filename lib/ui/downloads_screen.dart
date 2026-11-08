import 'dart:async';

import 'package:flutter/material.dart';

import '../api/download.dart';
import '../service/download_controller.dart';
import '../translations.i18n.dart';
import 'design/components.dart';
import 'design/tokens.dart';

/// Downloads: overview, queue control and history.
///
/// The screen is a pure view over [DownloadController]; every action goes through it so the
/// native queue stays the only source of truth.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final DownloadController controller = DownloadController.instance;
  final TextEditingController _search = TextEditingController();

  DownloadFilter _filter = DownloadFilter.all;
  bool _searchOpen = false;
  String _query = '';
  bool _selectionMode = false;
  final Set<int> _selected = <int>{};
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    controller.attach();
    controller.refreshStorage();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // Only repaint while something is counting down or transferring.
      bool needsTick = controller.downloads.any((d) =>
          d.awaitingRetry ||
          d.state == DownloadState.DOWNLOADING ||
          d.state == DownloadState.POST);
      if (needsTick) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _search.dispose();
    super.dispose();
  }

  // --- actions ------------------------------------------------------------------------------

  void _toggleSelection(Download download) {
    if (download.id == null) return;
    setState(() {
      if (!_selectionMode) {
        _selectionMode = true;
      }
      if (!_selected.add(download.id!)) {
        _selected.remove(download.id!);
      }
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
  }

  Future<void> _confirmClearHistory(DownloadState state) async {
    final bool ok = await rfConfirm(
      context,
      title: state == DownloadState.DONE ? 'Clear downloaded history?' : 'Clear history?',
      message: 'This only removes the entries from this list. '
          'Downloaded music stays on your device and remains available offline.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok) return;
    await controller.clearHistory(state);
    _snack('History cleared. Your files were not deleted.');
  }

  Future<void> _removeEntry(Download download, {bool offerDelete = false}) async {
    if (offerDelete && download.state.isDone) {
      final String? choice = await rfSheet<String>(
        context,
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  RfTokens.gutter, RfTokens.s3, RfTokens.gutter, RfTokens.s2),
              child: Text(download.title ?? 'Download', style: RfTokens.of(context).title),
            ),
            _sheetAction(
              context,
              icon: Icons.playlist_remove,
              label: 'Remove from list, keep the file',
              onTap: () => Navigator.of(context).pop('keep'),
            ),
            _sheetAction(
              context,
              icon: Icons.delete_outline,
              label: 'Remove and delete the file',
              danger: true,
              onTap: () => Navigator.of(context).pop('delete'),
            ),
            const SizedBox(height: RfTokens.s3),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'delete') {
        final bool ok = await rfConfirm(
          context,
          title: 'Delete the file?',
          message: 'The audio file will be deleted from your device. '
              'This cannot be undone.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (!ok) return;
        await controller.remove(download, deleteFile: true);
        _snack('Entry and file removed.');
        return;
      }
      await controller.remove(download);
      _snack('Entry removed. The file was kept.');
      return;
    }
    await controller.remove(download);
    _snack('Entry removed. The file was kept.');
  }

  Future<void> _cancelWithUndo(Download download) async {
    await controller.cancel(download);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Download cancelled.'),
        action: SnackBarAction(
          label: 'Undo'.i18n,
          onPressed: () => controller.resume(download),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
  }

  List<Download> get _visible {
    if (_filter == DownloadFilter.all && _query.isEmpty) {
      return controller.downloads;
    }
    return controller.filtered(filter: _filter, query: _query);
  }

  // --- build --------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final RfTokens tokens = RfTokens.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) {
        return Scaffold(
          backgroundColor: tokens.background,
          appBar: AppBar(
            backgroundColor: tokens.background,
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: false,
            titleSpacing: RfTokens.gutter,
            title: Text('Downloads'.i18n, style: tokens.title),
            actions: [
              RfIconAction(
                icon: _searchOpen ? Icons.search_off : Icons.search,
                tooltip: _searchOpen ? 'Close search'.i18n : 'Search'.i18n,
                onPressed: () {
                  setState(() {
                    _searchOpen = !_searchOpen;
                    if (!_searchOpen) {
                      _search.clear();
                      _query = '';
                    }
                  });
                },
              ),
              _buildOverflowMenu(context, tokens),
              const SizedBox(width: RfTokens.s2),
            ],
          ),
          body: _buildBody(context, tokens),
          bottomNavigationBar: _selectionMode ? _buildSelectionBar(context, tokens) : null,
        );
      },
    );
  }

  Widget _buildOverflowMenu(BuildContext context, RfTokens tokens) {
    return PopupMenuButton<String>(
      tooltip: 'More actions'.i18n,
      icon: Icon(Icons.more_vert, size: 20, color: tokens.textSecondary),
      color: tokens.surface,
      onSelected: (String value) async {
        switch (value) {
          case 'retryAll':
            await controller.retryAllFailed();
            _snack('Retrying failed downloads.');
            break;
          case 'pauseAll':
            await controller.pauseQueue();
            break;
          case 'resumeAll':
            await controller.startQueue();
            break;
          case 'clearDone':
            await _confirmClearHistory(DownloadState.DONE);
            break;
          case 'clearCancelled':
            await _confirmClearHistory(DownloadState.CANCELLED);
            break;
        }
      },
      itemBuilder: (BuildContext context) => [
        PopupMenuItem<String>(
          value: 'retryAll',
          child: Text('Retry all failed'.i18n),
          enabled: controller.summary.failed > 0,
        ),
        PopupMenuItem<String>(
          value: controller.running ? 'pauseAll' : 'resumeAll',
          child: Text(controller.running ? 'Pause all'.i18n : 'Resume all'.i18n),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'clearDone',
          child: Text('Clear downloaded history'.i18n),
          enabled: controller.summary.completed > 0,
        ),
        PopupMenuItem<String>(
          value: 'clearCancelled',
          child: Text('Clear cancelled entries'.i18n),
          enabled: controller.summary.cancelled > 0,
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, RfTokens tokens) {
    if (controller.loading && !controller.loaded) {
      return ListView(
        padding: const EdgeInsets.only(top: RfTokens.s4),
        children: const [
          RfSkeletonRow(),
          RfSkeletonRow(),
          RfSkeletonRow(),
          RfSkeletonRow(),
        ],
      );
    }

    if (controller.loadError != null && controller.downloads.isEmpty) {
      return RfErrorState(
        message: controller.loadError!,
        onRetry: controller.refresh,
      );
    }

    final List<Download> visible = _visible;

    return Column(
      children: [
        _buildHeader(context, tokens),
        if (_searchOpen)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: RfTokens.gutter),
            child: RfSearchField(
              controller: _search,
              hint: 'Search downloads',
              onChanged: (String value) => setState(() => _query = value),
            ),
          ),
        RfFilterBar<DownloadFilter>(
          items: DownloadFilter.values,
          selected: _filter,
          labelBuilder: (DownloadFilter filter) => filter.label.i18n,
          countBuilder: (DownloadFilter filter) =>
              controller.downloads.where((d) => filter.matches(d)).length,
          onSelected: (DownloadFilter filter) => setState(() => _filter = filter),
        ),
        const RfHairline(),
        Expanded(child: _buildList(context, tokens, visible)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, RfTokens tokens) {
    final DownloadSummary summary = controller.summary;
    final bool hasAny = controller.downloads.isNotEmpty;

    String headline;
    String detail;

    if (summary.active > 0) {
      headline = summary.active == 1
          ? '1 download in progress'
          : '${summary.active} downloads in progress';
      final int waiting = summary.queued + summary.paused;
      detail = waiting > 0
          ? '$waiting waiting · ${formatBytes(summary.downloadedBytes)} of '
              '${formatBytes(summary.totalBytes)}'
          : '${formatBytes(summary.downloadedBytes)} of ${formatBytes(summary.totalBytes)}';
    } else if (summary.queued > 0 || summary.paused > 0) {
      headline = controller.running
          ? 'Starting the queue'
          : '${summary.queued + summary.paused} waiting';
      detail = controller.running
          ? 'Preparing the next track'
          : 'Paused — nothing is downloading right now';
    } else if (summary.failed > 0) {
      headline = summary.failed == 1 ? '1 download failed' : '${summary.failed} downloads failed';
      detail = 'Retry them, or remove the entries from this list';
    } else if (hasAny) {
      headline = 'Up to date';
      detail = '${summary.completed} downloaded · ${formatBytes(summary.downloadedBytes)} offline';
    } else {
      headline = 'Downloads';
      detail = 'Downloaded music is available offline and never disappears by itself';
    }

    final int estimated = controller.estimatedRemainingBytes();
    final String storageLine = controller.freeBytes > 0
        ? '${formatBytes(controller.freeBytes)} free'
            '${estimated > 0 ? ' · ~${formatBytes(estimated)} needed' : ''}'
        : '';

    final bool lowStorage =
        controller.freeBytes > 0 && estimated > 0 && estimated > controller.freeBytes;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          RfTokens.gutter, RfTokens.s2, RfTokens.gutter, RfTokens.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary.active > 0 || summary.queued > 0 || summary.paused > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: RfTokens.s3),
              child: RfProgress(
                value: summary.overallProgress,
                indeterminate: summary.active > 0 && summary.totalBytes <= 0,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(headline, style: tokens.display, maxLines: 2),
                    const SizedBox(height: RfTokens.s1),
                    Text(detail, style: tokens.caption),
                    if (storageLine.isNotEmpty) ...[
                      const SizedBox(height: RfTokens.s1),
                      Text(
                        storageLine,
                        style: tokens.caption.copyWith(
                          color: lowStorage ? tokens.warning : tokens.textTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: RfTokens.s3),
              if (hasAny)
                controller.running
                    ? RfIconAction(
                        icon: Icons.pause,
                        tooltip: 'Pause all'.i18n,
                        onPressed: controller.pauseQueue,
                      )
                    : _hasResumable
                        ? RfIconAction(
                            icon: Icons.play_arrow,
                            tooltip: 'Resume all'.i18n,
                            onPressed: controller.startQueue,
                          )
                        : const SizedBox.shrink(),
            ],
          ),
          if (controller.needsAuth) ...[
            const SizedBox(height: RfTokens.s3),
            _buildNotice(
              tokens,
              icon: Icons.lock_outline,
              text:
                  'Sign in to Deezer again to continue downloading. The queue is kept.',
            ),
          ] else if (lowStorage) ...[
            const SizedBox(height: RfTokens.s3),
            _buildNotice(
              tokens,
              icon: Icons.sd_card_alert_outlined,
              text:
                  'Low storage: the queue needs about ${formatBytes(estimated)}, '
                  '${formatBytes(controller.freeBytes)} are free.',
            ),
          ],
        ],
      ),
    );
  }

  bool get _hasResumable => controller.downloads.any(
      (d) => d.state.isPaused || d.state.isQueued || d.state.isFailed);

  Widget _buildNotice(RfTokens tokens, {required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.all(RfTokens.s3),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(left: BorderSide(color: tokens.warning, width: 2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tokens.warning),
          const SizedBox(width: RfTokens.s2),
          Expanded(child: Text(text, style: tokens.caption)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, RfTokens tokens, List<Download> visible) {
    if (controller.downloads.isEmpty) {
      return RfEmptyState(
        icon: Icons.download_outlined,
        title: 'Nothing downloaded yet'.i18n,
        message:
            'Use the download button on a track, album or playlist. '
                'Progress, failures and history show up here.',
      );
    }

    if (visible.isEmpty) {
      return RfEmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: 'No downloads match'.i18n,
        message: _query.isNotEmpty
            ? 'Nothing matches "$_query". Try a different search or filter.'
            : 'Nothing in this section right now.',
        action: RfSecondaryButton(
          label: 'Clear filters'.i18n,
          onPressed: () => setState(() {
            _filter = DownloadFilter.all;
            _query = '';
            _search.clear();
          }),
        ),
      );
    }

    // Group headers only make sense in the "all" view.
    final bool grouped = _filter == DownloadFilter.all && _query.isEmpty;
    final List<Widget> children = [];

    if (grouped) {
      final Map<String, List<Download>> sections = controller.grouped();
      void addSection(String key, String label) {
        final List<Download> items = sections[key] ?? const [];
        if (items.isEmpty) return;
        children.add(RfSectionHeader(label));
        for (Download download in items) {
          children.add(_row(context, tokens, download));
        }
      }

      addSection('active', 'Downloading');
      addSection('waiting', 'Queue');
      addSection('failed', 'Needs attention');
      addSection('finished', 'Finished');
    } else {
      for (Download download in visible) {
        children.add(_row(context, tokens, download));
      }
    }

    children.add(const SizedBox(height: RfTokens.s7));

    return ListView(
      padding: EdgeInsets.zero,
      children: children,
    );
  }

  Widget _row(BuildContext context, RfTokens tokens, Download download) {
    final bool selected = download.id != null && _selected.contains(download.id);
    final Widget content = _DownloadRow(
      download: download,
      selected: selected,
      selectionMode: _selectionMode,
      tokens: tokens,
      onTap: () {
        if (_selectionMode) {
          _toggleSelection(download);
        } else {
          _showActions(download);
        }
      },
      onLongPress: () => _toggleSelection(download),
      onPrimaryAction: () => _primaryAction(download),
      onMenu: () => _showActions(download),
    );

    return Dismissible(
      key: ValueKey<String>('download-${download.id}'),
      direction: _selectionMode
          ? DismissDirection.none
          : (download.state.isActive || download.state.isQueued || download.state.isPaused
              ? DismissDirection.horizontal
              : DismissDirection.endToStart),
      background: _swipeBackground(tokens, pause: true),
      secondaryBackground: _swipeBackground(tokens, pause: false),
      confirmDismiss: (DismissDirection direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Pause / resume without confirmation: reversible.
          if (download.state.isActive || download.state.isQueued) {
            await controller.pause(download);
          } else if (download.state.isPaused) {
            await controller.resume(download);
          }
          return false;
        }
        if (download.state.isActive || download.state.isQueued || download.state.isPaused) {
          await _cancelWithUndo(download);
          return false;
        }
        final bool ok = await rfConfirm(
          context,
          title: 'Remove from the list?',
          message: 'The audio file stays on your device. '
              'Only the entry in this list is removed.',
          confirmLabel: 'Remove',
        );
        if (!ok) return false;
        await controller.remove(download);
        return true;
      },
      child: content,
    );
  }

  Widget _swipeBackground(RfTokens tokens, {required bool pause}) {
    return Container(
      color: tokens.surfaceHigh,
      alignment: pause ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: RfTokens.gutter),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pause) ...[
            Icon(Icons.pause_circle_outline, size: 18, color: tokens.textSecondary),
            const SizedBox(width: RfTokens.s2),
            Text('Pause'.i18n, style: tokens.caption),
          ] else ...[
            Text('Cancel'.i18n, style: tokens.caption),
            const SizedBox(width: RfTokens.s2),
            Icon(Icons.close, size: 18, color: tokens.danger),
          ],
        ],
      ),
    );
  }

  Future<void> _primaryAction(Download download) async {
    if (download.state.isActive) {
      await controller.pause(download);
      return;
    }
    if (download.state.isPaused) {
      await controller.resume(download);
      return;
    }
    if (download.state.isFailed || download.state.isCancelled) {
      await controller.retry(download);
      return;
    }
    if (download.state.isQueued) {
      await controller.moveToFront(download);
      _snack('Moved to the front of the queue.');
    }
  }

  Future<void> _showActions(Download download) async {
    final RfTokens tokens = RfTokens.of(context);
    await rfSheet<void>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                RfTokens.gutter, RfTokens.s2, RfTokens.gutter, RfTokens.s1),
            child: Text(download.title ?? 'Download', style: tokens.title),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                RfTokens.gutter, 0, RfTokens.gutter, RfTokens.s3),
            child: Text(
              '${download.state.label} · ${download.qualityLabel}'
              '${download.filesize > 0 ? ' · ${formatBytes(download.filesize)}' : ''}',
              style: tokens.caption,
            ),
          ),
          const RfHairline(),
          if (download.state.isActive)
            _sheetAction(context,
                icon: Icons.pause,
                label: 'Pause'.i18n,
                onTap: () {
              Navigator.of(context).pop();
              controller.pause(download);
            }),
          if (download.state.isActive || download.state.isQueued)
            _sheetAction(context,
                icon: Icons.close,
                label: 'Cancel'.i18n,
                onTap: () {
              Navigator.of(context).pop();
              _cancelWithUndo(download);
            }),
          if (download.state.isPaused)
            _sheetAction(context,
                icon: Icons.play_arrow,
                label: 'Resume'.i18n,
                onTap: () {
              Navigator.of(context).pop();
              controller.resume(download);
            }),
          if (download.state.isFailed || download.state.isCancelled)
            _sheetAction(context,
                icon: Icons.refresh,
                label: 'Retry'.i18n,
                onTap: () {
              Navigator.of(context).pop();
              controller.retry(download);
            }),
          if (download.state.isQueued || download.state.isPaused)
            _sheetAction(context,
                icon: Icons.vertical_align_top,
                label: 'Move to front'.i18n,
                onTap: () {
              Navigator.of(context).pop();
              controller.moveToFront(download);
            }),
          _sheetAction(
            context,
            icon: Icons.flag_outlined,
            label: 'Priority: ${download.priority.label}',
            onTap: () {
              Navigator.of(context).pop();
              _showPrioritySheet(download);
            },
          ),
          const RfHairline(),
          _sheetAction(
            context,
            icon: Icons.playlist_remove,
            label: 'Remove from list'.i18n,
            onTap: () {
              Navigator.of(context).pop();
              _removeEntry(download, offerDelete: true);
            },
          ),
          if (download.metadataWarning != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  RfTokens.gutter, RfTokens.s2, RfTokens.gutter, RfTokens.s3),
              child: Text(
                'Audio saved, but ${download.metadataWarning} could not be added. '
                'You can retry the metadata by removing and downloading again.',
                style: tokens.caption.copyWith(color: tokens.warning),
              ),
            ),
          const SizedBox(height: RfTokens.s3),
        ],
      ),
    );
  }

  Future<void> _showPrioritySheet(Download download) async {
    final RfTokens tokens = RfTokens.of(context);
    await rfSheet<void>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                RfTokens.gutter, RfTokens.s3, RfTokens.gutter, RfTokens.s2),
            child: Text('Priority'.i18n, style: tokens.title),
          ),
          for (DownloadPriority priority in DownloadPriority.values)
            _sheetAction(
              context,
              icon: download.priority == priority
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              label: priority.label,
              onTap: () {
                Navigator.of(context).pop();
                controller.setPriority(download, priority);
              },
            ),
          const SizedBox(height: RfTokens.s3),
        ],
      ),
    );
  }

  Widget _sheetAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final RfTokens tokens = RfTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: RfTokens.gutter, vertical: RfTokens.s3),
        child: Row(
          children: [
            Icon(icon, size: 20, color: danger ? tokens.danger : tokens.textSecondary),
            const SizedBox(width: RfTokens.s3),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  color: danger ? tokens.danger : tokens.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context, RfTokens tokens) {
    final List<Download> selected = controller.downloads
        .where((d) => d.id != null && _selected.contains(d.id))
        .toList();
    final bool anyFailed = selected.any((d) => d.state.isFailed || d.state.isCancelled);
    final bool anyPaused = selected.any((d) => d.state.isPaused);
    final bool anyActive = selected.any((d) => d.state.isActive || d.state.isQueued);

    return Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  RfTokens.gutter, RfTokens.s2, RfTokens.s2, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${selected.length} selected',
                      style: tokens.caption.copyWith(color: tokens.textPrimary),
                    ),
                  ),
                  RfIconAction(
                    icon: Icons.close,
                    tooltip: 'Clear selection'.i18n,
                    onPressed: _clearSelection,
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                  RfTokens.gutter, 0, RfTokens.gutter, RfTokens.s2),
              child: Row(
                children: [
                  if (anyActive)
                    _batchAction(tokens, Icons.pause, 'Pause', () async {
                      for (Download d in selected) {
                        if (d.state.isActive || d.state.isQueued) await controller.pause(d);
                      }
                      _clearSelection();
                    }),
                  if (anyPaused)
                    _batchAction(tokens, Icons.play_arrow, 'Resume', () async {
                      for (Download d in selected) {
                        if (d.state.isPaused) await controller.resume(d);
                      }
                      _clearSelection();
                    }),
                  if (anyFailed)
                    _batchAction(tokens, Icons.refresh, 'Retry', () async {
                      for (Download d in selected) {
                        if (d.state.isFailed || d.state.isCancelled) {
                          await controller.retry(d);
                        }
                      }
                      _clearSelection();
                    }),
                  _batchAction(tokens, Icons.low_priority, 'Low priority', () async {
                    for (Download d in selected) {
                      await controller.setPriority(d, DownloadPriority.low);
                    }
                    _clearSelection();
                  }),
                  _batchAction(tokens, Icons.playlist_remove, 'Remove', () async {
                    final bool ok = await rfConfirm(
                      context,
                      title: 'Remove ${selected.length} entries?',
                      message: 'Downloaded files stay on your device; only the list entries '
                          'are removed.',
                      confirmLabel: 'Remove',
                    );
                    if (!ok) return;
                    for (Download d in selected) {
                      await controller.remove(d);
                    }
                    _clearSelection();
                  }),
                  _batchAction(tokens, Icons.close, 'Cancel', () async {
                    for (Download d in selected) {
                      if (d.state.isActive || d.state.isQueued) await controller.cancel(d);
                    }
                    _clearSelection();
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _batchAction(
      RfTokens tokens, IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: RfTokens.s2),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17, color: tokens.textSecondary),
        label: Text(label,
            style: TextStyle(fontSize: 13, color: tokens.textPrimary)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: RfTokens.s3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RfTokens.rSm),
            side: BorderSide(color: tokens.hairline),
          ),
        ),
      ),
    );
  }
}

/// One queue row: artwork, title, state line, progress and actions.
class _DownloadRow extends StatelessWidget {
  final Download download;
  final bool selected;
  final bool selectionMode;
  final RfTokens tokens;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPrimaryAction;
  final VoidCallback onMenu;

  const _DownloadRow({
    required this.download,
    required this.selected,
    required this.selectionMode,
    required this.tokens,
    required this.onTap,
    required this.onLongPress,
    required this.onPrimaryAction,
    required this.onMenu,
  });

  Color get _statusColor {
    switch (download.state) {
      case DownloadState.DONE:
        return tokens.success;
      case DownloadState.ERROR:
      case DownloadState.DEEZER_ERROR:
        return tokens.danger;
      case DownloadState.PAUSED:
        return tokens.warning;
      case DownloadState.CANCELLED:
        return tokens.textTertiary;
      default:
        return tokens.accent;
    }
  }

  String get _secondary {
    switch (download.state) {
      case DownloadState.DOWNLOADING:
        final int? eta = download.etaSeconds;
        final String speed = download.speed > 0 ? '${formatBytes(download.speed)}/s' : '';
        final String progress = download.filesize > 0
            ? '${formatBytes(download.received)} / ${formatBytes(download.filesize)}'
            : formatBytes(download.received);
        return [
          progress,
          if (speed.isNotEmpty) speed,
          if (eta != null) '${formatDuration(eta)} left',
        ].join(' · ');
      case DownloadState.POST:
        return 'Processing · decrypting and tagging';
      case DownloadState.NONE:
        final int? retry = download.retryInSeconds;
        if (retry != null) {
          return 'Retry in ${retry}s · attempt ${download.attempts}';
        }
        return '${download.qualityLabel} · waiting';
      case DownloadState.PAUSED:
        return '${download.qualityLabel} · paused'
            '${download.received > 0 ? ' at ${formatBytes(download.received)}' : ''}';
      case DownloadState.DONE:
        return '${download.qualityLabel}'
            '${download.filesize > 0 ? ' · ${formatBytes(download.filesize)}' : ''}'
            '${download.metadataWarning != null ? ' · tags incomplete' : ''}';
      case DownloadState.ERROR:
      case DownloadState.DEEZER_ERROR:
      case DownloadState.CANCELLED:
        return download.errorText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showProgress = download.state.isActive ||
        (download.state.isPaused && download.progress > 0) ||
        (download.state.isQueued && download.awaitingRetry);

    return Material(
      color: selected ? tokens.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              RfTokens.gutter, RfTokens.s3, RfTokens.s2, RfTokens.s3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: RfTokens.s2),
                  child: Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? tokens.accent : tokens.textTertiary,
                  ),
                ),
              RfArtwork(url: download.image, size: RfTokens.artworkSm),
              const SizedBox(width: RfTokens.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            download.title ?? 'Unknown track',
                            style: tokens.rowTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: RfTokens.s2),
                        if (download.state.isDone)
                          RfStatus('Saved', color: tokens.success)
                        else if (download.state.isFailed)
                          RfStatus('Failed', color: tokens.danger)
                        else if (download.state.isPaused)
                          RfStatus('Paused', color: tokens.warning)
                        else if (download.state.isQueued)
                          RfStatus('Queued', color: tokens.textTertiary)
                        else if (download.state.isActive)
                          RfStatus(
                            download.state == DownloadState.POST ? 'Processing' : 'Downloading',
                            color: tokens.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _secondary,
                      style: tokens.caption.copyWith(
                        color: download.state.isFailed ? tokens.danger : tokens.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (showProgress) ...[
                      const SizedBox(height: RfTokens.s2),
                      RfProgress(
                        value: download.progress,
                        indeterminate: download.state == DownloadState.POST,
                        color: _statusColor,
                        height: 2,
                      ),
                    ],
                  ],
                ),
              ),
              if (!selectionMode) ...[
                RfIconAction(
                  icon: _primaryIcon,
                  tooltip: _primaryTooltip,
                  onPressed: onPrimaryAction,
                ),
                RfIconAction(
                  icon: Icons.more_vert,
                  tooltip: 'More'.i18n,
                  onPressed: onMenu,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData get _primaryIcon {
    if (download.state.isActive) return Icons.pause;
    if (download.state.isPaused) return Icons.play_arrow;
    if (download.state.isFailed || download.state.isCancelled) return Icons.refresh;
    if (download.state.isQueued) return Icons.vertical_align_top;
    return Icons.more_horiz;
  }

  String get _primaryTooltip {
    if (download.state.isActive) return 'Pause'.i18n;
    if (download.state.isPaused) return 'Resume'.i18n;
    if (download.state.isFailed || download.state.isCancelled) return 'Retry'.i18n;
    if (download.state.isQueued) return 'Move to front'.i18n;
    return 'Actions'.i18n;
  }
}
