/// Identity of this build of the host — the only source file that differs
/// between the debug and release trees. The debug and release instances run
/// side by side on one machine, so each needs its own config directory
/// (`~/.config/<toolId>`) and MCP port. Every other file is shared and
/// mirrored byte for byte (`tool/sync_debug_to_release.sh`).
library;

/// Config directory name and instance id (debug tree).
const String kHostToolId = 'vibe_studio_debug';

/// Default MCP listen port (debug tree).
const int kHostDefaultPort = 7840;
