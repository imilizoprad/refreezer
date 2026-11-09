import 'dart:async';

import 'package:draggable_scrollbar/draggable_scrollbar.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../api/download.dart';
import '../service/download_controller.dart';
import '../translations.i18n.dart';
import 'cached_image.dart';
import 'elements.dart';
import 'menu.dart';

/// Downloads: queue overview, control and history.
///
/// The screen is a pure view over [DownloadController]; every action goes through it so the
/// native queue stays the only source of truth. It deliberately uses the same widgets as the rest
/// of the app (FreezerAppBar, ListTile rows, FreezerDivider, MenuSheet, Fluttertoast) so it does
/// not look like a different application.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final DownloadController controller = DownloadController.instance;
  final TextEditingController _search = TextEditingController();
  final ScrollController _scrollController = ScrollController();

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
    _scrollController.dispose();
    super.dispose();
  }

  // --- helpers -------------------------------------------------------------------------------

  void _toast(String message) {
    Fluttertoast.showToast(
      msg: message,
      gravity: ToastGravity.BOTTOM,
      toastLength: Toast.LENGTH_SHORT,
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            child: Text('Cancel'.i18n),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          TextButton(
            child: Text(confirmLabel),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toggleSelection(Download download) {
    if (download.id == null) return;
    setState(() {
      if (!_selectionMode) _selectionMode = true;
      if (!_selected.add(download.id!)) _selected.remove(download.id!);
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
  }

  List<Download> get _visible {
    if (_filter == DownloadFilter.all && _query.isEmpty) return controller.downloads;
    return controller.filtered(filter: _filter, query: _query);
  }

  bool get _hasResumable => controller.downloads
      .any((d) => d.state.isPaused || d.state.isQueued || d.state.isFailed);

  // --- actions -------------------------------------------------------------------------------

  Future<void> _clearHistory(DownloadState state) async {
    final bool ok = await _confirm(
      title: state == DownloadState.DONE ? 'Clear downloaded history?' : 'Clear history?',
      message: 'This only removes the entries from this list. '
          'Downloaded music stays on your device and remains available offline.',
      confirmLabel: 'Clear',
    );
    if (!ok) return;
    await controller.clearHistory(state);
    _toast('History cleared. Your files were not deleted.');
  }

  Future<void> _cancelWithUndo(Download download) async {
    await controller.cancel(download);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Download cancelled.'.i18n),
        action: SnackBarAction(
          label: 'Undo'.i18n,
          onPressed: () => controller.resume(download),
        ),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _primaryAction(Download download) async {
    if (download.state.isActive) {
      await controller.pause(download);
      _toast('Download paused.'.i18n);
      return;
    }
    if (download.state.isPaused) {
      await controller.resume(download);
      _toast('Download resumed.'.i18n);
      return;
    }
    if (download.state.isFailed || download.state.isCancelled) {
      await controller.retry(download);
      _toast('Retrying download.'.i18n);
      return;
    }
    if (download.state.isQueued) {
      await controller.moveToFront(download);
      _toast('Moved to the front of the queue.');
    }
  }

  Future<void> _removeEntry(Download download, {bool offerDelete = false}) async {
    if (offerDelete && download.state.isDone) {
      final String? choice = await _pickRemoval(download);
      if (choice == null) return;
      if (choice == 'delete') {
        final bool ok = await _confirm(
          title: 'Delete the file?',
          message: 'The audio file will be deleted from your device. This cannot be undone.',
          confirmLabel: 'Delete',
        );
        if (!ok) return;
        await controller.remove(download, deleteFile: true);
        _toast('Entry and file removed.');
        return;
      }
      await controller.remove(download);
      _toast('Entry removed. The file was kept.');
      return;
    }
    await controller.remove(download);
    _toast('Entry removed. The file was kept.');
  }

  Future<String?> _pickRemoval(Download download) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(download.title ?? 'Download'.i18n),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('keep'),
            child: Text('Remove from list, keep the file'.i18n),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: Text('Remove and delete the file'.i18n, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _showActions(Download download) async {
    ListTile action(IconData icon, String label, VoidCallback onTap, {bool danger = false}) {
      return ListTile(
        leading: Icon(icon, color: danger ? Colors.red : null),
        title: Text(label, style: danger ? const TextStyle(color: Colors.red) : null),
        onTap: () {
          Navigator.of(context).pop();
          onTap();
        },
      );
    }

    MenuSheet().show(context, <Widget>[
      ListTile(
        title: Text(
          download.title ?? 'Download'.i18n,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18.0),
        ),
        subtitle: Text(
          '${download.state.label} · ${download.qualityLabel}'
          '${download.filesize > 0 ? ' · ${formatBytes(download.filesize)}' : ''}',
          maxLines: 2,
        ),
      ),
      const FreezerDivider(),
      if (download.state.isActive)
        action(Icons.pause, 'Pause'.i18n, () => controller.pause(download)),
      if (download.state.isPaused)
        action(Icons.play_arrow, 'Resume'.i18n, () => controller.resume(download)),
      if (download.state.isActive || download.state.isQueued)
        action(Icons.close, 'Cancel'.i18n, () => _cancelWithUndo(download)),
      if (download.state.isFailed || download.state.isCancelled)
        action(Icons.refresh, 'Retry'.i18n, () => controller.retry(download)),
      if (download.state.isQueued || download.state.isPaused)
        action(Icons.vertical_align_top, 'Move to front'.i18n,
            () => controller.moveToFront(download)),
      action(Icons.flag_outlined, 'Priority: ${download.priority.label}', () {
        _showPriority(download);
      }),
      action(Icons.playlist_remove, 'Remove from list'.i18n,
          () => _removeEntry(download, offerDelete: true)),
    ]);
  }

  void _showPriority(Download download) {
    ListTile option(DownloadPriority priority) {
      return ListTile(
        leading: Icon(
          download.priority == priority
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
        ),
        title: Text(priority.label),
        onTap: () {
          Navigator.of(context).pop();
          controller.setPriority(download, priority);
        },
      );
    }

    MenuSheet().show(context, <Widget>[
      ListTile(
        title: Text('Priority'.i18n,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18.0)),
      ),
      const FreezerDivider(),
      for (DownloadPriority priority in DownloadPriority.values) option(priority),
    ]);
  }

  // --- build ---------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) {
        return Scaffold(
          appBar: FreezerAppBar(
            'Downloads'.i18n,
            actions: <Widget>[
              IconButton(
                icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
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
              _filterMenu(context),
              _overflowMenu(context),
              Container(width: 8.0),
            ],
          ),
          body: _buildBody(context),
          bottomNavigationBar: _selectionMode ? _buildSelectionBar(context) : null,
        );
      },
    );
  }

  Widget _filterMenu(BuildContext context) {
    final List<DownloadFilter> filters = DownloadFilter.values;
    return PopupMenuButton<DownloadFilter>(
      color: Theme.of(context).scaffoldBackgroundColor,
      icon: const Icon(Icons.filter_list, semanticLabel: 'Filter'),
      onSelected: (DownloadFilter filter) => setState(() => _filter = filter),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<DownloadFilter>>[
        for (DownloadFilter filter in filters)
          PopupMenuItem<DownloadFilter>(
            value: filter,
            child: Row(
              children: <Widget>[
                Icon(
                  filter == _filter ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20.0,
                  color: filter == _filter ? Theme.of(context).primaryColor : null,
                ),
                Container(width: 12.0),
                Expanded(child: Text(filter.label.i18n, style: popupMenuTextStyle())),
                Text(
                  '${controller.downloads.where((d) => filter.matches(d)).length}',
                  style: popupMenuTextStyle().copyWith(color: Colors.grey),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _overflowMenu(BuildContext context) {
    return PopupMenuButton<String>(
      color: Theme.of(context).scaffoldBackgroundColor,
      icon: const Icon(Icons.more_vert, semanticLabel: 'More actions'),
      onSelected: (String value) async {
        switch (value) {
          case 'retryAll':
            await controller.retryAllFailed();
            _toast('Retrying failed downloads.');
            break;
          case 'pauseAll':
            await controller.pauseQueue();
            _toast('Queue paused.'.i18n);
            break;
          case 'resumeAll':
            await controller.startQueue();
            _toast('Queue resumed.'.i18n);
            break;
          case 'clearDone':
            await _clearHistory(DownloadState.DONE);
            break;
          case 'clearCancelled':
            await _clearHistory(DownloadState.CANCELLED);
            break;
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'retryAll',
          enabled: controller.summary.failed > 0,
          child: Text('Retry all failed'.i18n, style: popupMenuTextStyle()),
        ),
        PopupMenuItem<String>(
          value: controller.running ? 'pauseAll' : 'resumeAll',
          child: Text(controller.running ? 'Pause all'.i18n : 'Resume all'.i18n,
              style: popupMenuTextStyle()),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'clearDone',
          enabled: controller.summary.completed > 0,
          child: Text('Clear downloaded history'.i18n, style: popupMenuTextStyle()),
        ),
        PopupMenuItem<String>(
          value: 'clearCancelled',
          enabled: controller.summary.cancelled > 0,
          child: Text('Clear cancelled entries'.i18n, style: popupMenuTextStyle()),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (controller.loading && !controller.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (controller.loadError != null && controller.downloads.isEmpty) {
      return _errorState(context);
    }

    return DraggableScrollbarWrapper(
      controller: _scrollController,
      child: ListView(
        controller: _scrollController,
        children: <Widget>[
          _header(context),
          if (_searchOpen) _searchField(context),
          const FreezerDivider(),
          ..._listContent(context),
          const SizedBox(height: 24.0),
        ],
      ),
    );
  }

  Widget _errorState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 64.0, color: Theme.of(context).primaryColor),
            const SizedBox(height: 12.0),
            Text(
              'Could not load the download queue'.i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8.0),
            Text(controller.loadError ?? '', textAlign: TextAlign.center),
            const SizedBox(height: 12.0),
            TextButton(
              child: Text('Retry'.i18n),
              onPressed: controller.refresh,
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 8.0),
      child: TextField(
        controller: _search,
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'Search downloads'.i18n,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Clear'.i18n,
            onPressed: () {
              _search.clear();
              setState(() => _query = '');
            },
          ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (String value) => setState(() => _query = value),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final DownloadSummary summary = controller.summary;
    final bool hasAny = controller.downloads.isNotEmpty;
    final Color accent = Theme.of(context).primaryColor;

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
      headline = 'Nothing queued';
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
      padding: const EdgeInsets.fromLTRB(16.0, 8.0, 8.0, 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (summary.active > 0 || summary.queued > 0 || summary.paused > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8.0, bottom: 12.0),
              child: LinearProgressIndicator(
                value: summary.totalBytes > 0 ? summary.overallProgress : null,
                minHeight: 3.0,
                backgroundColor: Theme.of(context).dividerColor,
                color: accent,
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      headline.i18n,
                      style: const TextStyle(fontSize: 20.0, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2.0),
                    Text(detail.i18n, style: const TextStyle(fontSize: 13.0)),
                    if (storageLine.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2.0),
                      Text(
                        storageLine,
                        style: TextStyle(
                          fontSize: 13.0,
                          color: lowStorage ? Colors.orange : Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (hasAny)
                controller.running
                    ? IconButton(
                        icon: const Icon(Icons.pause, size: 28.0),
                        tooltip: 'Pause all'.i18n,
                        onPressed: () async {
                          await controller.pauseQueue();
                          _toast('Queue paused.'.i18n);
                        },
                      )
                    : _hasResumable
                        ? IconButton(
                            icon: const Icon(Icons.play_arrow, size: 28.0),
                            tooltip: 'Resume all'.i18n,
                            onPressed: () async {
                              await controller.startQueue();
                              _toast('Queue resumed.'.i18n);
                            },
                          )
                        : const SizedBox(width: 0, height: 0),
            ],
          ),
          if (controller.needsAuth)
            _notice(
              context,
              icon: Icons.lock_outline,
              text: 'Sign in to Deezer again to continue downloading. The queue is kept.',
            )
          else if (lowStorage)
            _notice(
              context,
              icon: Icons.sd_card_alert_outlined,
              text: 'Low storage: the queue needs about ${formatBytes(estimated)}, '
                  '${formatBytes(controller.freeBytes)} are free.',
            ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, {required IconData icon, required String text}) {
    return Padding(
      padding: const EdgeInsets.only(top: 12.0, right: 8.0),
      child: Container(
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.orange),
          borderRadius: BorderRadius.circular(4.0),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 18.0, color: Colors.orange),
            Container(width: 8.0),
            Expanded(child: Text(text.i18n, style: const TextStyle(fontSize: 13.0))),
          ],
        ),
      ),
    );
  }

  List<Widget> _listContent(BuildContext context) {
    if (controller.downloads.isEmpty) {
      return <Widget>[
        _emptyState(
          context,
          icon: Icons.download_outlined,
          title: 'Nothing downloaded yet'.i18n,
          message: 'Use the download button on a track, album, playlist or artist. '
              'Progress, failures and history show up here.',
        ),
      ];
    }

    final List<Download> visible = _visible;
    if (visible.isEmpty) {
      return <Widget>[
        _emptyState(
          context,
          icon: Icons.filter_alt_off_outlined,
          title: 'No downloads match'.i18n,
          message: _query.isNotEmpty
              ? 'Nothing matches "$_query". Try a different search or filter.'
              : 'Nothing in this section right now.',
          action: TextButton(
            child: Text('Clear filters'.i18n),
            onPressed: () => setState(() {
              _filter = DownloadFilter.all;
              _query = '';
              _search.clear();
            }),
          ),
        ),
      ];
    }

    final List<Widget> children = <Widget>[];
    final bool grouped = _filter == DownloadFilter.all && _query.isEmpty;

    if (grouped) {
      final Map<String, List<Download>> sections = controller.grouped();
      void addSection(String key, String label) {
        final List<Download> items = sections[key] ?? const <Download>[];
        if (items.isEmpty) return;
        children.add(_sectionHeader(label));
        for (Download download in items) {
          children.addAll(_row(context, download));
        }
      }

      addSection('active', 'Downloading');
      addSection('waiting', 'Queue');
      addSection('failed', 'Needs attention');
      addSection('finished', 'Finished');
    } else {
      for (Download download in visible) {
        children.addAll(_row(context, download));
      }
    }

    return children;
  }

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 4.0),
      child: Text(
        label.i18n.toUpperCase(),
        style: const TextStyle(fontSize: 12.0, fontWeight: FontWeight.w300),
      ),
    );
  }

  Widget _emptyState(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 64.0, color: Theme.of(context).primaryColor),
          const SizedBox(height: 12.0),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8.0),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...<Widget>[
            const SizedBox(height: 12.0),
            action,
          ],
        ],
      ),
    );
  }

  List<Widget> _row(BuildContext context, Download download) {
    final bool selected = download.id != null && _selected.contains(download.id);

    final Widget tile = Container(
      color: selected ? Theme.of(context).primaryColor.withOpacity(0.12) : null,
      child: _DownloadRow(
        download: download,
        selectionMode: _selectionMode,
        selected: selected,
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
      ),
    );

    if (_selectionMode) {
      return <Widget>[tile, const FreezerDivider()];
    }

    final bool activeOrWaiting =
        download.state.isActive || download.state.isQueued || download.state.isPaused;

    return <Widget>[
      Dismissible(
        key: ValueKey<String>('download-${download.id}'),
        direction:
            activeOrWaiting ? DismissDirection.horizontal : DismissDirection.endToStart,
        background: _swipeBackground(context, pause: true),
        secondaryBackground: _swipeBackground(context, pause: false),
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
          if (activeOrWaiting) {
            await _cancelWithUndo(download);
            return false;
          }
          final bool ok = await _confirm(
            title: 'Remove from the list?',
            message: 'The audio file stays on your device. '
                'Only the entry in this list is removed.',
            confirmLabel: 'Remove',
          );
          if (!ok) return false;
          await controller.remove(download);
          return true;
        },
        child: tile,
      ),
      const FreezerDivider(),
    ];
  }

  Widget _swipeBackground(BuildContext context, {required bool pause}) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: pause ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (pause) ...<Widget>[
            const Icon(Icons.pause_circle_outline, size: 20.0),
            Container(width: 8.0),
            Text('Pause'.i18n),
          ] else ...<Widget>[
            Text('Cancel'.i18n),
            Container(width: 8.0),
            const Icon(Icons.close, size: 20.0, color: Colors.red),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context) {
    final List<Download> selected = controller.downloads
        .where((d) => d.id != null && _selected.contains(d.id))
        .toList();
    final bool anyFailed = selected.any((d) => d.state.isFailed || d.state.isCancelled);
    final bool anyPaused = selected.any((d) => d.state.isPaused);
    final bool anyActive = selected.any((d) => d.state.isActive || d.state.isQueued);

    Widget button(IconData icon, String label, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 4.0),
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18.0),
          label: Text(label),
        ),
      );
    }

    return BottomAppBar(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: 0.0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(width: 16.0),
              Expanded(
                child: Text(
                  '${selected.length} selected',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear selection'.i18n,
                onPressed: _clearSelection,
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              children: <Widget>[
                if (anyActive)
                  button(Icons.pause, 'Pause'.i18n, () async {
                    for (Download d in selected) {
                      if (d.state.isActive || d.state.isQueued) await controller.pause(d);
                    }
                    _clearSelection();
                  }),
                if (anyPaused)
                  button(Icons.play_arrow, 'Resume'.i18n, () async {
                    for (Download d in selected) {
                      if (d.state.isPaused) await controller.resume(d);
                    }
                    _clearSelection();
                  }),
                if (anyFailed)
                  button(Icons.refresh, 'Retry'.i18n, () async {
                    for (Download d in selected) {
                      if (d.state.isFailed || d.state.isCancelled) {
                        await controller.retry(d);
                      }
                    }
                    _clearSelection();
                  }),
                button(Icons.low_priority, 'Low priority'.i18n, () async {
                  for (Download d in selected) {
                    await controller.setPriority(d, DownloadPriority.low);
                  }
                  _clearSelection();
                }),
                button(Icons.playlist_remove, 'Remove'.i18n, () async {
                  final bool ok = await _confirm(
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
                if (anyActive)
                  button(Icons.close, 'Cancel'.i18n, () async {
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
    );
  }
}

/// Simple wrapper that keeps the scrollbar of the app style in one place.
class DraggableScrollbarWrapper extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  const DraggableScrollbarWrapper({super.key, required this.controller, required this.child});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollbar.rrect(
      controller: controller,
      backgroundColor: Theme.of(context).primaryColor,
      child: child,
    );
  }
}

/// One queue row: artwork, title, state line, progress and actions.
///
/// Uses the same geometry as [TrackTile] (48px artwork, ListTile padding) so the list looks like
/// the rest of the app.
class _DownloadRow extends StatelessWidget {
  final Download download;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPrimaryAction;
  final VoidCallback onMenu;

  const _DownloadRow({
    required this.download,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onPrimaryAction,
    required this.onMenu,
  });

  String get _secondary {
    switch (download.state) {
      case DownloadState.DOWNLOADING:
        final int? eta = download.etaSeconds;
        final String speed = download.speed > 0 ? '${formatBytes(download.speed)}/s' : '';
        final String progress = download.filesize > 0
            ? '${formatBytes(download.received)} / ${formatBytes(download.filesize)}'
            : formatBytes(download.received);
        return <String>[
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

  IconData get _trailingIcon {
    if (download.state.isActive) return Icons.pause;
    if (download.state.isDone) return Icons.download_done;
    if (download.state.isPaused) return Icons.paused;
    if (download.state.isFailed) return Icons.error_outline;
    if (download.state.isCancelled) return Icons.cancel_outlined;
    if (download.state == DownloadState.POST) return Icons.autorenew;
    return Icons.schedule;
  }

  Color? _trailingColor(BuildContext context) {
    if (download.state.isFailed) return Colors.red;
    if (download.state.isPaused) return Colors.orange;
    if (download.state.isDone) return Colors.green;
    if (download.state.isActive) return Theme.of(context).primaryColor;
    return null;
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

  @override
  Widget build(BuildContext context) {
    final bool showProgress = download.state.isActive ||
        (download.state.isPaused && download.progress > 0) ||
        (download.state.isQueued && download.awaitingRetry);

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (selectionMode)
            Padding(
              padding: const EdgeInsets.only(right: 4.0),
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 22.0,
                color: selected ? Theme.of(context).primaryColor : Colors.grey,
              ),
            ),
          CachedImage(url: download.image ?? '', width: 48.0),
        ],
      ),
      title: Text(
        download.title ?? 'Unknown track',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: download.state.isActive ? Theme.of(context).primaryColor : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _secondary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: download.state.isFailed ? Colors.red : null,
            ),
          ),
          if (showProgress)
            Padding(
              padding: const EdgeInsets.only(top: 6.0, right: 8.0),
              child: LinearProgressIndicator(
                value: download.state == DownloadState.POST ? null : download.progress,
                minHeight: 2.0,
                backgroundColor: Theme.of(context).dividerColor,
                color: Theme.of(context).primaryColor,
              ),
            ),
        ],
      ),
      trailing: selectionMode
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(_trailingIcon, size: 20.0, color: _trailingColor(context)),
                Container(width: 4.0),
                IconButton(
                  icon: Icon(_primaryIcon, size: 22.0),
                  tooltip: _primaryTooltip,
                  onPressed: onPrimaryAction,
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 22.0),
                  tooltip: 'More'.i18n,
                  onPressed: onMenu,
                ),
              ],
            ),
    );
  }
}
