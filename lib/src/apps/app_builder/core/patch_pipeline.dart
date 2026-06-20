/// App Builder uses the platform's patch pipeline (dry-run validate →
/// apply atomic). The fork is gone; this re-exports the single impl.
export 'package:appplayer_studio/base.dart'
    show PatchPipeline, PatchPipelineImpl;
