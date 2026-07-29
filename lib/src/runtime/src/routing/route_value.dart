/// Normalisation of a `RouteValue` into page JSON.
///
/// Spec v1.4 §1.2.1 widens a route value to any `DefinitionSource` (§1.9.1):
///
///   * `"ui://pages/main"`              — resource on the current origin (v1.0)
///   * `{ "type": "page", … }`          — inline PageDefinition (v1.0)
///   * `{ "page": …, "transition": … }` — per-route transition wrapper (v1.3)
///   * `{ "$ref": …, "from": … }`       — another origin (v1.4)
///   * `"{{binding}}"`                  — a definition held in state (v1.4)
///
/// The last two normalise to a page whose content is a single [`view`] widget.
/// That is deliberate: `view` already owns resolution, origin scoping, state
/// isolation, `fallback`, and cycle detection, so a route-level source and a
/// widget-level source cannot drift apart. The spec calls them two surfaces of
/// one concept (§1.9.4); here they are literally the same code path.
library;

/// True when [value] can be turned into page JSON without asking the host's
/// page loader for anything — i.e. everything except a plain resource URI.
bool routeValueIsLocal(dynamic value) => _normalise(value) != null;

/// Page JSON for a route value that needs no loader round-trip, or `null` when
/// [value] is a plain resource URI the caller must fetch through its loader.
Map<String, dynamic>? routeValueToPageJson(dynamic value) => _normalise(value);

/// A stable cache key for a route value. Resource URIs key by themselves (so
/// two routes pointing at the same page share a cache entry); structural values
/// key by identity of their normalised shape.
String routeValueCacheKey(String routePath, dynamic value) =>
    value is String && !_isBinding(value) ? value : 'route:$routePath';

Map<String, dynamic>? _normalise(dynamic value) {
  // v1.3 transition wrapper — unwrap and normalise what it carries. The
  // transition itself is presentation and is handled by the caller.
  if (value is Map && value.containsKey('page') && !value.containsKey('type')) {
    return _normalise(value['page']);
  }

  if (value is Map) {
    final map = Map<String, dynamic>.from(value);

    // Qualified reference to another origin (v1.4) — hand to `view`.
    if (map.containsKey(r'$ref')) return _viewPage(map);

    // Inline PageDefinition (v1.0). `screen` is the legacy alias (§17.3.5).
    final type = map['type'];
    if (type == 'page' || type == 'screen') return map;

    // Any other inline definition is a widget tree; wrap it as a page so the
    // routing layer always receives page JSON.
    if (type != null) {
      return <String, dynamic>{'type': 'page', 'content': map};
    }

    return null;
  }

  // A binding may hold a whole definition (v1.4) — `view` resolves it.
  if (value is String && _isBinding(value)) return _viewPage(value);

  // Plain resource URI: the caller's page loader owns this.
  return null;
}

Map<String, dynamic> _viewPage(dynamic source) => <String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{'type': 'view', 'source': source},
    };

bool _isBinding(String s) => s.startsWith('{{') && s.endsWith('}}');
