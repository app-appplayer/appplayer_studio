/// Application metadata model — MCP UI DSL spec §11 (Bundle Metadata).
///
/// Captures the optional descriptive fields stamped on an
/// `ApplicationDefinition` (or returned by the `ui://app/info`
/// well-known resource) so embedders can render app-listing UI
/// (launcher grids, info dialogs, app-store cards) without having
/// to parse the raw DSL JSON.
///
/// All nested references (`icon`, `screenshots`, `splash.image`,
/// `publisher.logo`) are assumed to be already resolved by the
/// server / runtime — a raw `bundle://` URI SHOULD NOT appear on
/// the outbound `ui://app/info` response (spec §11.6).
///
/// `PublisherInfo` and `SplashConfig` are reused from `mcp_bundle`
/// to keep a single definition for the shared bundle-manifest types.
library app_metadata;

import 'package:mcp_bundle/mcp_bundle.dart' show PublisherInfo, SplashConfig;

export 'package:mcp_bundle/mcp_bundle.dart' show PublisherInfo, SplashConfig;

/// Creation / update timestamps — spec §11.3.
class TimestampInfo {
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const TimestampInfo({this.createdAt, this.updatedAt});

  factory TimestampInfo.fromJson(Map<String, dynamic> json) {
    return TimestampInfo(
      createdAt: _parseIso(json['createdAt']),
      updatedAt: _parseIso(json['updatedAt']),
    );
  }

  static DateTime? _parseIso(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  Map<String, dynamic> toJson() => {
        if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
      };
}

/// Top-level application metadata — spec §11.1.
///
/// `title` and `version` are surfaced here for convenience so embedders
/// have a single struct to display, even though they are also required
/// on `ApplicationDefinition` itself.
class DslAppMetadata {
  final String? id;
  final String title;
  final String version;
  final String? description;
  final String? icon;
  final String? category;
  final PublisherInfo? publisher;
  final TimestampInfo? timestamps;
  final List<String>? screenshots;
  final SplashConfig? splash;

  const DslAppMetadata({
    this.id,
    required this.title,
    required this.version,
    this.description,
    this.icon,
    this.category,
    this.publisher,
    this.timestamps,
    this.screenshots,
    this.splash,
  });

  /// Parse from either an `ApplicationDefinition` DSL root or a
  /// `ui://app/info` resource payload (same shape per spec §11.6).
  factory DslAppMetadata.fromJson(Map<String, dynamic> json) {
    return DslAppMetadata(
      id: json['id'] as String?,
      title: json['title'] as String? ?? json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      description: json['description'] as String?,
      icon: json['icon'] as String?,
      category: json['category'] as String?,
      publisher: _parsePublisher(json['publisher']),
      timestamps: json['timestamps'] is Map<String, dynamic>
          ? TimestampInfo.fromJson(json['timestamps'] as Map<String, dynamic>)
          : null,
      screenshots: (json['screenshots'] as List<dynamic>?)?.cast<String>(),
      splash: json['splash'] is Map<String, dynamic>
          ? SplashConfig.fromJson(json['splash'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Spec §11.2 names the publisher site field `website`, while
  /// [PublisherInfo] (shared with bundle manifests) stores it as `url`.
  /// Normalise on the way in so downstream code sees a single shape.
  static PublisherInfo? _parsePublisher(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final name = raw['name'] as String?;
    if (name == null || name.isEmpty) return null;
    final website = raw['website'] as String? ?? raw['url'] as String?;
    return PublisherInfo(
      name: name,
      logo: raw['logo'] as String?,
      url: website,
      email: raw['email'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'title': title,
        'version': version,
        if (description != null) 'description': description,
        if (icon != null) 'icon': icon,
        if (category != null) 'category': category,
        if (publisher != null) 'publisher': _publisherToJson(publisher!),
        if (timestamps != null) 'timestamps': timestamps!.toJson(),
        if (screenshots != null) 'screenshots': screenshots,
        if (splash != null) 'splash': splash!.toJson(),
      };

  /// Emit the spec §11.2 shape (`website` rather than `url`).
  static Map<String, dynamic> _publisherToJson(PublisherInfo p) => {
        'name': p.name,
        if (p.logo != null) 'logo': p.logo,
        if (p.url != null) 'website': p.url,
        if (p.email != null) 'email': p.email,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DslAppMetadata &&
          id == other.id &&
          title == other.title &&
          version == other.version &&
          description == other.description &&
          icon == other.icon &&
          category == other.category);

  @override
  int get hashCode => Object.hash(id, title, version, description, icon, category);
}
