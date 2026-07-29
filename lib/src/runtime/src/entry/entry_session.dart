/// Holds the entry and identity a runtime was opened under (MCP UI DSL §8.9).
///
/// The host owns the facts; this only stores them, publishes them where the
/// binding engine can read them, and rebuilds bound widgets when identity
/// changes mid-session (§8.9.4).
library entry_session;

import '../state/state_manager.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show EntryContext, IdentityContext, IdentityPromotion, PromotionOutcome;

/// Reserved state keys the session publishes under. Documents read them
/// through `entry.*` / `identity.*` bindings and MUST NOT write them — the
/// state action executor rejects writes to these roots.
class EntryStateKeys {
  EntryStateKeys._();

  static const String entry = 'entry';
  static const String identity = 'identity';

  /// Roots a document may never assign to (§8.9.2 "All read-only").
  static const Set<String> readOnlyRoots = <String>{entry, identity};

  /// Whether [path] targets a read-only entry/identity root.
  static bool isReadOnly(String path) {
    final root = path.contains('.') ? path.substring(0, path.indexOf('.')) : path;
    return readOnlyRoots.contains(root);
  }
}

/// Asks the host to identify the current viewer, or to let go of that
/// identity.
///
/// Returns why the attempt ended as it did, so a document can tell a decline
/// from an impossibility — see [PromotionOutcome]. Anything but
/// [PromotionOutcome.promoted] leaves the session carrying what it had.
typedef IdentityPromoter = Future<IdentityPromotion> Function();

/// Per-runtime holder for `entry.*` and `identity.*`.
class EntrySession {
  EntrySession({required StateManager stateManager})
      : _stateManager = stateManager;

  final StateManager _stateManager;

  EntryContext? _entry;
  IdentityContext _identity = IdentityContext.guest;
  IdentityPromoter? _promoter;
  IdentityPromoter? _releaser;

  /// The entry this runtime was opened under, or `null` when it was opened
  /// normally (a launcher tile, an in-app navigation).
  EntryContext? get entry => _entry;

  IdentityContext get identity => _identity;

  /// Whether the host wired anything at all. A runtime with no host support
  /// resolves every §8.9 binding to `null` (§8.9.6).
  bool get hasHostSupport => _entry != null || _promoter != null;

  /// Seed the entry. Called once by the host as it opens the definition —
  /// after any install or sign-in interstitial, never replayed from a cache.
  void adoptEntry(EntryContext? entry) {
    _entry = entry;
    _publishEntry();
  }

  /// Seed or replace the current principal. Publishing through the state
  /// manager is what re-evaluates bound expressions in place (§8.9.4) — the
  /// document is not rebuilt and its state is not discarded.
  void adoptIdentity(IdentityContext identity) {
    if (_identity == identity) return;
    _identity = identity;
    _publishIdentity();
  }

  /// Wire the host's promotion handlers. Absent handlers make
  /// `identity.promote` / `identity.release` unsupported rather than failing
  /// (§8.9.6).
  void registerPromotion({
    IdentityPromoter? onPromote,
    IdentityPromoter? onRelease,
  }) {
    _promoter = onPromote;
    _releaser = onRelease;
    _publishIdentity();
  }

  bool get canPromote => _promoter != null && _identity.canPromote;

  bool get canRelease => _releaser != null;

  /// Run the host's promotion.
  Future<IdentityPromotion> promote() async {
    final promoter = _promoter;
    if (promoter == null || !_identity.canPromote) {
      return const IdentityPromotion.unavailable();
    }
    return _apply(await promoter());
  }

  /// Run the host's release.
  Future<IdentityPromotion> release() async {
    final releaser = _releaser;
    if (releaser == null) return const IdentityPromotion.unavailable();
    return _apply(await releaser());
  }

  /// Adopt the result of a transition that actually produced one. A host that
  /// returns `promoted` with the identity already in force is not an error —
  /// it simply changes nothing, and `adoptIdentity` no-ops.
  IdentityPromotion _apply(IdentityPromotion result) {
    final next = result.identity;
    if (result.outcome == PromotionOutcome.promoted && next != null) {
      adoptIdentity(next);
    }
    return result;
  }

  /// Publish both roots. Called by the engine once the state manager exists.
  void publish() {
    _publishEntry();
    _publishIdentity();
  }

  void _publishEntry() {
    _stateManager.set(EntryStateKeys.entry, _entry?.toBindingMap());
  }

  void _publishIdentity() {
    // `canPromote` is the intersection of what the entry's policy allows and
    // what this host can actually do — a document that offers sign-in the
    // host cannot perform has a dead button.
    final effective = _identity.copyWith(
      canPromote: _identity.canPromote && _promoter != null,
    );
    _stateManager.set(EntryStateKeys.identity, effective.toBindingMap());
  }
}
