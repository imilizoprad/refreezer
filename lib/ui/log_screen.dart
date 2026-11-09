import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../translations.i18n.dart';
import 'elements.dart';

class ApplicationLogViewer extends StatefulWidget {
  const ApplicationLogViewer({super.key});

  @override
  _ApplicationLogViewerState createState() => _ApplicationLogViewerState();
}

class _ApplicationLogViewerState extends State<ApplicationLogViewer> {
  List<String> data = [];

  //Load log from file
  Future _load() async {
    String path = p.join((await getExternalStorageDirectory())!.path, 'refreezer.log');
    File file = File(path);
    if (await file.exists()) {
      String d = await file.readAsString();
      setState(() {
        data = d.replaceAll('\r', '').split('\n');
      });
    }
  }

  //Get color by log type
  Color? color(String line) {
    if (line.startsWith('[log] SEVERE:')) return Colors.red;
    if (line.startsWith('[log] WARNING:')) return Colors.orange[600];
    return null;
  }

  @override
  void initState() {
    _load();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: FreezerAppBar('Application Log'.i18n),
        body: ListView.builder(
          itemCount: data.length,
          itemBuilder: (context, i) {
            return Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                data[i],
                style: TextStyle(fontSize: 14.0, color: color(data[i])),
              ),
            );
          },
        ));
  }
}

/// Viewer for the native downloader log (`DownloadLog.java` writes to
/// `<external files>/download.log`).
///
/// `DownloadsSettings` links to this screen; the class was referenced but missing, which made the
/// whole app fail to compile.
class DownloadLogViewer extends StatefulWidget {
  const DownloadLogViewer({super.key});

  @override
  _DownloadLogViewerState createState() => _DownloadLogViewerState();
}

class _DownloadLogViewerState extends State<DownloadLogViewer> {
  List<String> data = [];
  bool loaded = false;

  Future _load() async {
    try {
      Directory? dir = await getExternalStorageDirectory();
      String path = p.join(dir!.path, 'download.log');
      File file = File(path);
      if (await file.exists()) {
        String d = await file.readAsString();
        if (!mounted) return;
        setState(() {
          data = d.replaceAll('\r', '').split('\n').where((l) => l.isNotEmpty).toList();
        });
      }
    } catch (_) {
      // A missing or unreadable log must never crash the screen.
    }
    if (!mounted) return;
    setState(() => loaded = true);
  }

  Color? color(String line) {
    String lower = line.toLowerCase();
    if (lower.contains('error') || lower.contains('fatal')) return Colors.red;
    if (lower.contains('warn')) return Colors.orange[600];
    return null;
  }

  @override
  void initState() {
    _load();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Download Log'.i18n),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : data.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(
                      'No download log entries yet.'.i18n,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: data.length,
                  itemBuilder: (context, i) {
                    return Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        data[i],
                        style: TextStyle(fontSize: 13.0, color: color(data[i])),
                      ),
                    );
                  },
                ),
    );
  }
}
