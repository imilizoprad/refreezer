import 'package:flutter_test/flutter_test.dart';
import 'package:refreezer/api/download_models.dart';

/// Regression tests for the download data model.
///
/// The ordinal order is the wire format shared with
/// `android/app/src/main/java/r/r/refreezer/Download.java` — changing it breaks saved queues.
void main() {
  group('DownloadState wire format', () {
    test('ordinals match the native enum exactly', () {
      expect(DownloadState.values.map((DownloadState s) => s.index).toList(),
          <int>[0, 1, 2, 3, 4, 5, 6, 7]);
      expect(DownloadState.NONE.index, 0);
      expect(DownloadState.DOWNLOADING.index, 1);
      expect(DownloadState.POST.index, 2);
      expect(DownloadState.DONE.index, 3);
      expect(DownloadState.DEEZER_ERROR.index, 4);
      expect(DownloadState.ERROR.index, 5);
      // Appended after ERROR so old persisted values keep their meaning.
      expect(DownloadState.PAUSED.index, 6);
      expect(DownloadState.CANCELLED.index, 7);
    });

    test('unknown or malformed ordinals fall back instead of throwing', () {
      expect(downloadStateFromIndex(99), DownloadState.NONE);
      expect(downloadStateFromIndex(-1), DownloadState.NONE);
      expect(downloadStateFromIndex(null), DownloadState.NONE);
      expect(downloadStateFromIndex('3'), DownloadState.NONE);
      expect(downloadStateFromIndex(6, fallback: DownloadState.ERROR),
          DownloadState.PAUSED);
    });

    test('state predicates do not overlap in surprising ways', () {
      expect(DownloadState.DOWNLOADING.isActive, isTrue);
      expect(DownloadState.POST.isActive, isTrue);
      expect(DownloadState.DOWNLOADING.isSettled, isFalse);
      expect(DownloadState.ERROR.isFailed, isTrue);
      expect(DownloadState.DEEZER_ERROR.isFailed, isTrue);
      expect(DownloadState.PAUSED.isSettled, isTrue);
      expect(DownloadState.NONE.isQueued, isTrue);
      expect(DownloadState.DONE.isDone, isTrue);
    });
  });

  group('Download parsing', () {
    test('fromJson reads every field the native service sends', () {
      final Download download = Download.fromJson(<String, dynamic>{
        'id': 7,
        'path': '/music/%artist% - %title%',
        'private': true,
        'trackId': '3135556',
        'streamTrackId': '3135556',
        'trackToken': 'token',
        'md5origin': 'md5',
        'mediaVersion': '5',
        'title': 'Harder, Better, Faster, Stronger',
        'image': 'https://example.invalid/cover.jpg',
        'quality': 3,
        'state': 6,
        'priority': 0,
        'attempts': 2,
        'nextRetryAt': 1700000000000,
        'createdAt': 1699999999000,
        'groupId': 'album:42',
        'errorKind': 'network',
        'errorMessage': 'timeout',
        'metadataWarning': 'tags',
        'received': 10,
        'filesize': 100,
      });

      expect(download.id, 7);
      expect(download.private, isTrue);
      expect(download.state, DownloadState.PAUSED);
      expect(download.priority, DownloadPriority.high);
      expect(download.attempts, 2);
      expect(download.groupId, 'album:42');
      expect(download.errorKind, 'network');
      expect(download.metadataWarning, 'tags');
      expect(download.progress, closeTo(0.1, 0.0001));
      expect(download.qualityLabel, 'MP3 320');
    });

    test('numeric strings are tolerated (older platform channel payloads)', () {
      final Download download = Download.fromJson(<String, dynamic>{
        'id': '12',
        'state': '3',
        'quality': '1',
        'received': '5',
        'filesize': '10',
      });
      expect(download.id, 12);
      expect(download.state, DownloadState.DONE);
      expect(download.quality, 1);
      expect(download.progress, 0.5);
    });

    test('missing optional counters default to zero, not null', () {
      final Download download = Download.fromJson(<String, dynamic>{});
      expect(download.received, 0);
      expect(download.filesize, 0);
      expect(download.attempts, 0);
      expect(download.progress, 0);
      expect(download.state, DownloadState.NONE);
      expect(download.priority, DownloadPriority.normal);
    });

    test('progress never divides by zero or exceeds 1', () {
      Download download = Download(filesize: 0, received: 100);
      expect(download.progress, 0);
      download = Download(filesize: 100, received: 250);
      expect(download.progress, 1);
      download = Download(filesize: 100, received: -5);
      expect(download.progress, 0);
    });

    test('progress updates merge without dropping persisted fields', () {
      final Download download = Download.fromJson(<String, dynamic>{
        'id': 1,
        'title': 'Track',
        'path': '/dest',
        'trackId': '9',
        'state': 1,
        'filesize': 200,
        'priority': 2,
        'createdAt': 123,
      });
      download.updateFromJson(<String, dynamic>{
        'state': 2,
        'received': 200,
        'filesize': 200,
        'speed': 4096,
      });
      expect(download.state, DownloadState.POST);
      expect(download.received, 200);
      expect(download.speed, 4096);
      // Untouched by progress events:
      expect(download.title, 'Track');
      expect(download.path, '/dest');
      expect(download.priority, DownloadPriority.low);
      expect(download.createdAt, 123);
    });
  });

  group('Failure reasons', () {
    test('every known failure kind has human readable copy', () {
      const List<String> kinds = <String>[
        'network',
        'timeout',
        'server',
        'auth',
        'storage',
        'permission',
        'unavailable',
        'processing',
        'duplicate',
        'cancelled',
        'interrupted',
        'metadata',
        'something-new',
      ];
      for (String kind in kinds) {
        final String text = Download(errorKind: kind).errorText;
        expect(text, isNotEmpty, reason: kind);
        expect(text.contains('null'), isFalse, reason: kind);
        expect(text.length, greaterThan(8), reason: kind);
      }
      expect(Download(errorKind: null).errorText, 'Download failed.');
    });

    test('auth failures are distinguishable from network failures', () {
      expect(Download(errorKind: 'auth').errorText,
          isNot(Download(errorKind: 'network').errorText));
      expect(Download(errorKind: 'storage').errorText,
          isNot(Download(errorKind: 'server').errorText));
    });
  });

  group('Retry timing', () {
    test('awaitingRetry is only true for queued jobs with a future retry time', () {
      final int now = DateTime.now().millisecondsSinceEpoch;
      Download download = Download(state: DownloadState.NONE, nextRetryAt: now + 30000);
      expect(download.awaitingRetry, isTrue);
      final int? seconds = download.retryInSeconds;
      expect(seconds, isNotNull);
      expect(seconds! >= 28 && seconds <= 30, isTrue);

      download = Download(state: DownloadState.DOWNLOADING, nextRetryAt: now + 30000);
      expect(download.awaitingRetry, isFalse);
      expect(download.retryInSeconds, isNull);

      download = Download(state: DownloadState.NONE, nextRetryAt: 0);
      expect(download.awaitingRetry, isFalse);
    });

    test('retry countdown never goes negative', () {
      final Download download = Download(
        state: DownloadState.NONE,
        nextRetryAt: DateTime.now().millisecondsSinceEpoch - 60000,
      );
      // nextRetryAt in the past is handled by the native scheduler; the getter must not crash.
      expect(download.retryInSeconds, isNotNull);
      expect(download.retryInSeconds! >= 0, isTrue);
    });
  });

  group('Duplicate prevention identity', () {
    test('same track, destination, quality and privacy share a key', () {
      final Download a = Download(
          trackId: '1', path: '/a', quality: 3, private: true);
      final Download b = Download(
          trackId: '1', path: '/a', quality: 3, private: true);
      expect(a.dedupeKey, b.dedupeKey);
    });

    test('a different destination, quality or privacy is a different download', () {
      final Download base = Download(
          trackId: '1', path: '/a', quality: 3, private: true);
      expect(base.dedupeKey,
          isNot(Download(trackId: '1', path: '/b', quality: 3, private: true).dedupeKey));
      expect(base.dedupeKey,
          isNot(Download(trackId: '1', path: '/a', quality: 1, private: true).dedupeKey));
      expect(base.dedupeKey,
          isNot(Download(trackId: '1', path: '/a', quality: 3, private: false).dedupeKey));
    });

    test('the key never depends on the display title (renames keep identity)', () {
      final Download a = Download(trackId: '1', path: '/a', title: 'Old title');
      final Download b = Download(trackId: '1', path: '/a', title: 'New title');
      expect(a.dedupeKey, b.dedupeKey);
    });
  });

  group('ETA', () {
    test('eta is only reported while downloading with a known speed', () {
      expect(Download(state: DownloadState.DOWNLOADING, speed: 0, filesize: 100).etaSeconds,
          isNull);
      expect(Download(state: DownloadState.NONE, speed: 100, filesize: 100).etaSeconds,
          isNull);
      final Download download = Download(
        state: DownloadState.DOWNLOADING,
        speed: 1000,
        received: 4000,
        filesize: 10000,
      );
      expect(download.etaSeconds, 6);
    });
  });
}
