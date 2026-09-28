/// What a signed-in Studio keeps in the account.
///
/// Account storage (`specs/platform/20-account-storage.md`) holds the records;
/// [SyncedDocument] holds the version each was read at and hands conflicts to
/// the merge that knows the format. This class only says which records a
/// Studio device keeps:
///
/// | record | scope | why |
/// |---|---|---|
/// | settings (theme) | `shell/common` | the person's taste crosses products |
/// | device profile | `device/<deviceId>` | the device declares whether it takes part |
///
/// `shell/studio` is reserved by the spec but nothing is defined to live
/// there yet, so nothing is written to it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'account_storage.dart';
import 'synced_document.dart';
import 'synced_settings.dart';

/// What a device says about itself (platform spec 20 §5).
///
/// Single writer — only this device writes its profile, so a conflict on it
/// is a broken rule rather than something to merge.
class DeviceProfile {
  const DeviceProfile({
    required this.product,
    required this.platform,
    required this.syncEnabled,
    required this.updatedAt,
  });

  final String product;
  final String platform;

  /// Whether this device sends and receives account state. A device that
  /// turned it off still writes this record: the switch is about mirroring,
  /// not about the device describing itself.
  final bool syncEnabled;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'product': product,
    'platform': platform,
    'syncEnabled': syncEnabled,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static DeviceProfile fromJson(Map<String, Object?> json) => DeviceProfile(
    product: '${json['product'] ?? ''}',
    platform: '${json['platform'] ?? ''}',
    syncEnabled: json['syncEnabled'] == true,
    updatedAt:
        DateTime.tryParse('${json['updatedAt']}') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

final DocumentCodec<DeviceProfile> deviceProfileCodec =
    DocumentCodec<DeviceProfile>(
      encode: (v) => Uint8List.fromList(utf8.encode(jsonEncode(v.toJson()))),
      decode:
          (r) => DeviceProfile.fromJson(
            jsonDecode(utf8.decode(r.body)) as Map<String, Object?>,
          ),
      contentType: 'application/json',
    );

/// The device profile record — `device/<deviceId>`, key `profile`.
SyncedDocument<DeviceProfile> deviceProfileDocument(
  AccountStorage storage,
  String deviceId,
) => SyncedDocument<DeviceProfile>.singleWriter(
  storage: storage,
  scope: StorageScope.device(deviceId),
  key: 'profile',
  codec: deviceProfileCodec,
);

/// The account and this device, joined. Made on sign-in, dropped on
/// sign-out.
class StudioCloudSync {
  StudioCloudSync({required this.storage, required String deviceId})
    : settings = settingsDocument(storage),
      profile = deviceProfileDocument(storage, deviceId);

  final AccountStorage storage;

  /// The person's taste — crosses products (`shell/common`).
  final SyncedDocument<SyncedSettings> settings;

  /// This device's own declaration (`device/<deviceId>`).
  final SyncedDocument<DeviceProfile> profile;
}
