/// App Builder uses the platform's settings model — the host's single
/// `VibeSettings` (tool config: workspace / MCP / LLM + panel widths +
/// recent projects) and the shared model catalog. The fork is gone; this
/// re-exports the standard settings types. App Builder's settings file
/// lives at `~/.config/app_builder_vibe/settings.json`
/// (`VibeSettings.defaultPath('app_builder_vibe')`).
export 'package:appplayer_studio/base.dart'
    show VibeSettings, VibeModelOption, kVibeModelCatalog;
