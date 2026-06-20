/// App Builder uses the platform's workspace FS port (the on-disk `.mbd/`
/// gateway — manifest + ui/app.json + ui/pages/*.json full-directory
/// layout, with atomic temp-rename writes). The fork is gone; this
/// re-exports the single port + its file-backed implementation.
export 'package:appplayer_studio/base.dart'
    show WorkspaceFsPort, FileWorkspaceFsPort;
