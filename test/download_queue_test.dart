import 'package:flutter_test/flutter_test.dart';
import 'package:refreezer/api/download_models.dart';

/// Queue logic that the Downloads screen relies on: ordering, filters, summary and estimates.
void main() {
  Download download({
    int id = 1,
    DownloadState state = DownloadState.NONE,
    DownloadPriority priority = DownloadPriority.normal,
    int createdAt = 0,
    int received = 0,
    int filesize = 0,
    String title = 'Track',
    String? errorKind,
  }) {
    return Download(
      id: id,
      state: state,
      priority: priority,
      createdAt: createdAt,
      received: received,
      filesize: filesize,
      title: title,
      errorKind: errorKind,
    );
  }

  group('Ordering', () {
    test('active work comes before the queue and history', () {
      final List<Download> items = <Download>[
        download(id: 1, state: DownloadState.DONE),
        download(id: 2, state: DownloadState.NONE),
        download(id: 3, state: DownloadState.DOWNLOADING),
        download(id: 4, state: DownloadState.ERROR, errorKind: 'network'),
      ];
      items.sort(compareDownloads);
      expect(items.map((Download d) => d.id).toList(), <int>[3, 2, 4, 1]);
    });

    test('queue order follows priority then creation order then id', () {
      final List<Download> items = <Download>[
        download(id: 1, createdAt: 300),
        download(id: 2, createdAt: 100, priority: DownloadPriority.low),
        download(id: 3, createdAt: 200, priority: DownloadPriority.high),
        download(id: 4, createdAt: 100),
        download(id: 5, createdAt: 100),
      ];
      items.sort(compareDownloads);
      expect(items.map((Download d) => d.id).toList(), <int>[3, 4, 5, 1, 2]);
    });

    test('comparison is a total order (never returns inconsistent results)', () {
      final Download a = download(id: 1, createdAt: 10);
      final Download b = download(id: 2, createdAt: 10);
      expect(compareDownloads(a, b) < 0, isTrue);
      expect(compareDownloads(b, a) > 0, isTrue);
      expect(compareDownloads(a, a), 0);
    });
  });

  group('Filters', () {
    final List<Download> items = <Download>[
      download(id: 1, state: DownloadState.DOWNLOADING),
      download(id: 2, state: DownloadState.POST),
      download(id: 3, state: DownloadState.NONE),
      download(id: 4, state: DownloadState.PAUSED),
      download(id: 5, state: DownloadState.ERROR),
      download(id: 6, state: DownloadState.DEEZER_ERROR),
      download(id: 7, state: DownloadState.DONE),
      download(id: 8, state: DownloadState.CANCELLED),
    ];

    List<int> idsFor(DownloadFilter filter) => items
        .where((Download d) => filter.matches(d))
        .map((Download d) => d.id!)
        .toList();

    test('active covers transferring and processing', () {
      expect(idsFor(DownloadFilter.active), <int>[1, 2]);
    });

    test('queued, paused, failed and downloaded are distinct', () {
      expect(idsFor(DownloadFilter.queued), <int>[3]);
      expect(idsFor(DownloadFilter.paused), <int>[4]);
      expect(idsFor(DownloadFilter.failed), <int>[5, 6]);
      expect(idsFor(DownloadFilter.completedDownload), <int>[7]);
    });

    test('history covers finished, failed and cancelled but not active work', () {
      expect(idsFor(DownloadFilter.history), <int>[5, 6, 7, 8]);
    });

    test('all matches everything', () {
      expect(idsFor(DownloadFilter.all).length, items.length);
    });
  });

  group('Search', () {
    test('query matching is case insensitive and whitespace tolerant', () {
      final Download track = download(title: 'Bohemian Rhapsody');
      expect(downloadMatchesQuery(track, 'bohemian'), isTrue);
      expect(downloadMatchesQuery(track, '  RHAPSODY '), isTrue);
      expect(downloadMatchesQuery(track, ''), isTrue);
      expect(downloadMatchesQuery(track, 'queen'), isFalse);
    });
  });

  group('Summary', () {
    test('counts every state and ignores unknown sizes', () {
      final DownloadSummary summary = DownloadSummary.from(<Download>[
        download(id: 1, state: DownloadState.DOWNLOADING, received: 50, filesize: 100),
        download(id: 2, state: DownloadState.POST, filesize: 100),
        download(id: 3, state: DownloadState.NONE),
        download(id: 4, state: DownloadState.PAUSED),
        download(id: 5, state: DownloadState.ERROR),
        download(id: 6, state: DownloadState.DONE, filesize: 200),
        download(id: 7, state: DownloadState.CANCELLED),
      ]);

      expect(summary.active, 2);
      expect(summary.queued, 1);
      expect(summary.paused, 1);
      expect(summary.failed, 1);
      expect(summary.completed, 1);
      expect(summary.cancelled, 1);
      expect(summary.total, 7);
      expect(summary.isIdle, isFalse);
      expect(summary.hasHistory, isTrue);
    });

    test('overall progress is bounded and zero when nothing is measurable', () {
      expect(DownloadSummary.from(<Download>[download()]).overallProgress, 0);
      final DownloadSummary half = DownloadSummary.from(<Download>[
        download(id: 1, state: DownloadState.DOWNLOADING, received: 50, filesize: 100),
        download(id: 2, state: DownloadState.DONE, received: 0, filesize: 100),
      ]);
      expect(half.overallProgress, closeTo(0.25, 0.0001));
    });

    test('an empty queue is idle', () {
      final DownloadSummary summary = DownloadSummary.from(<Download>[]);
      expect(summary.isIdle, isTrue);
      expect(summary.total, 0);
      expect(summary.overallProgress, 0);
    });
  });

  group('Storage estimation', () {
    test('pending work is estimated from known sizes', () {
      final int estimate = estimateRemainingBytes(<Download>[
        download(id: 1, state: DownloadState.DOWNLOADING, received: 25, filesize: 100),
        download(id: 2, state: DownloadState.NONE, filesize: 100),
        download(id: 3, state: DownloadState.DONE, filesize: 100),
      ], defaultTrackBytes: 1000);
      expect(estimate, 175);
    });

    test('unknown sizes use the fallback estimate', () {
      final int estimate = estimateRemainingBytes(
        <Download>[download(id: 1, state: DownloadState.NONE)],
        defaultTrackBytes: 500,
      );
      expect(estimate, 500);
    });

    test('nothing pending returns -1 instead of a fake number', () {
      expect(
        estimateRemainingBytes(<Download>[download(state: DownloadState.DONE)]),
        -1,
      );
      expect(estimateRemainingBytes(<Download>[]), -1);
    });

    test('already over-downloaded tracks never produce negative estimates', () {
      final int estimate = estimateRemainingBytes(<Download>[
        download(id: 1, state: DownloadState.PAUSED, received: 200, filesize: 100),
      ]);
      expect(estimate, 0);
    });
  });

  group('Formatting', () {
    test('formatBytes covers the unit boundaries', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-10), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1 MB');
      expect(formatBytes(5 * 1024 * 1024 * 1024), '5 GB');
    });

    test('formatDuration formats minutes and hours', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(5), '0:05');
      expect(formatDuration(65), '1:05');
      expect(formatDuration(3725), '1:02:05');
      expect(formatDuration(-4), '0:00');
    });
  });
}
