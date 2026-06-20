// App Builder uses the single Studio design palette — `VibeTokens`
// forwards to the host's `VbuTokens` so chrome, the bundle runtime, and
// App Builder all share one theme. The fork (an identical parallel token
// set) is gone; this re-exports the Studio tokens.
export 'package:appplayer_studio/base.dart' show VibeTokens;
