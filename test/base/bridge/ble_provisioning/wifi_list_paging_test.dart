// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/ble_provisioning/test/wifi_list_paging_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'package:appplayer_studio/src/base/bridge/ble_provisioning/ble_provisioning.dart';
import 'package:flutter_test/flutter_test.dart';

/// Walking a device's paged Wi-Fi list.
///
/// This exists because of a defect that only a real radio and a real room
/// surfaced. The device capped its list at five networks and then truncated it
/// again to fit a single ATT read, so a scan that found twenty-one networks
/// reached the user's screen as three — with the device logging a successful
/// scan and the host rendering a perfectly valid short list. Neither end had
/// any way to tell that networks were missing.
///
/// A single GATT attribute value is capped at 512 bytes by ATT and that cannot
/// be raised, so the fix is paging, and the contract that matters is that
/// walking to the end yields EVERY network regardless of how many there are.
void main() {
  /// A device serving [total] networks [perPage] at a time.
  ({
    Future<Map<String, Object?>> Function() read,
    Future<void> Function(int) seek,
    int Function() reads,
  }) device({required int total, required int perPage, bool paged = true, int gen = 1}) {
    var cursor = 0;
    var reads = 0;
    return (
      read: () async {
        reads++;
        final end = (cursor + perPage).clamp(0, total);
        return <String, Object?>{
          'gen': gen,
          'from': cursor,
          'total': total,
          if (paged) 'more': end < total,
          'aps': <Object?>[
            for (var i = cursor; i < end; i++)
              {'ssid': 'network-$i', 'rssi': -40 - i, 'secure': i.isEven},
          ],
        };
      },
      seek: (from) async => cursor = from,
      reads: () => reads,
    );
  }

  test('a list spanning many pages arrives complete', () async {
    final d = device(total: 21, perPage: 4);
    final aps = await pageWifiList(read: d.read, seek: d.seek);

    expect(aps.length, 21, reason: 'every network the device saw');
    expect(aps.first.ssid, 'network-0');
    expect(aps.last.ssid, 'network-20',
        reason: 'the tail is what a truncating device drops first');
    expect(d.reads(), 6, reason: '21 in pages of 4 is six round trips');
  });

  for (final perPage in <int>[1, 3, 7, 21, 50]) {
    test('page size $perPage still yields all 21', () async {
      final d = device(total: 21, perPage: perPage);
      final aps = await pageWifiList(read: d.read, seek: d.seek);
      expect(aps.length, 21);
      expect(aps.map((a) => a.ssid).toSet().length, 21,
          reason: 'no page is fetched twice or skipped');
    });
  }

  test('a device that serves everything in one read is not paged again',
      () async {
    final d = device(total: 6, perPage: 6);
    final aps = await pageWifiList(read: d.read, seek: d.seek);
    expect(aps.length, 6);
    expect(d.reads(), 1);
  });

  test('a device predating paging still works', () async {
    // No `more` field at all — the whole list in one read, which is what the
    // firmware served before this contract existed.
    final d = device(total: 5, perPage: 5, paged: false);
    final aps = await pageWifiList(read: d.read, seek: d.seek);
    expect(aps.length, 5);
    expect(d.reads(), 1, reason: 'absent `more` must not mean "keep asking"');
  });

  test('an empty scan is not an error', () async {
    final d = device(total: 0, perPage: 4);
    expect(await pageWifiList(read: d.read, seek: d.seek), isEmpty);
  });

  test('a device that always claims more cannot hang onboarding', () async {
    // Onboarding is the first thing a user does with a device; a walk that
    // never returns would leave the sheet spinning with no way out.
    var reads = 0;
    final aps = await pageWifiList(
      read: () async {
        reads++;
        return <String, Object?>{
          'more': true,
          'aps': <Object?>[
            {'ssid': 'net-$reads', 'rssi': -50, 'secure': true},
          ],
        };
      },
      seek: (_) async {},
      maxPages: 8,
    );
    expect(reads, 8, reason: 'bounded');
    expect(aps.length, 8, reason: 'and returns what it did gather');
  });

  test('a rescan mid-walk restarts it rather than splicing two lists', () async {
    // The device rescans on its own schedule. Pages from two different scans
    // describe two different lists, and joining them yields one that was never
    // true of either — a network can appear twice or drop out of the middle.
    var reads = 0;
    var cursor = 0;
    final aps = await pageWifiList(
      read: () async {
        reads++;
        // The list is replaced once, part-way through the first walk.
        final gen = reads <= 2 ? 1 : 2;
        final total = gen == 1 ? 10 : 6;
        final end = (cursor + 4).clamp(0, total);
        return <String, Object?>{
          'gen': gen,
          'from': cursor,
          'total': total,
          'more': end < total,
          'aps': <Object?>[
            for (var i = cursor; i < end; i++)
              {'ssid': 'g$gen-$i', 'rssi': -40 - i, 'secure': true},
          ],
        };
      },
      seek: (from) async => cursor = from,
    );

    expect(aps.every((a) => a.ssid.startsWith('g2-')), isTrue,
        reason: 'only the surviving scan is reported');
    expect(aps.length, 6);
    expect(aps.map((a) => a.ssid).toSet().length, aps.length,
        reason: 'and nothing is duplicated by the restart');
  });

  test('a device rescanning constantly still answers', () async {
    // Restarting forever would be its own hang. Bounded, returning whatever
    // the last attempt gathered.
    var reads = 0;
    final aps = await pageWifiList(
      read: () async {
        reads++;
        return <String, Object?>{
          'gen': reads,
          'more': true,
          'aps': <Object?>[
            {'ssid': 'n$reads', 'rssi': -50, 'secure': true},
          ],
        };
      },
      seek: (_) async {},
      maxRestarts: 2,
    );
    expect(reads, lessThan(32), reason: 'gave up before the page bound');
    expect(aps, isA<List<WifiAp>>());
  });

  test('a device without a generation field is walked as before', () async {
    final d = device(total: 9, perPage: 4);
    final aps = await pageWifiList(read: d.read, seek: d.seek);
    expect(aps.length, 9);
  });

  test('a page promising more but carrying nothing ends the walk', () async {
    // Otherwise the cursor never advances and the loop runs to its bound on
    // every onboarding, delaying the sheet for no gain.
    var reads = 0;
    final aps = await pageWifiList(
      read: () async {
        reads++;
        return <String, Object?>{'more': true, 'aps': <Object?>[]};
      },
      seek: (_) async {},
    );
    expect(reads, 1);
    expect(aps, isEmpty);
  });
}
