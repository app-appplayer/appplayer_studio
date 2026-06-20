/// Host-app surface for consumer hosts that build ON standard (e.g. the
/// pro tier). Exports the universal host app and its extension seam so a
/// dependent package can subclass [VibeStudioHostApp] and override
/// `registerExtensions` to add tools / surfaces (marketplace, etc.)
/// without forking the open base.
library;

export 'src/main/vibe_studio_host_app.dart'
    show VibeStudioHostApp, StudioExtensionContext;
