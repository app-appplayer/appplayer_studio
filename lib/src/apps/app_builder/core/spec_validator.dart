/// App Builder uses the platform's spec validator. The fork is gone; this
/// re-exports the single impl (validates via mcp_bundle, emits the
/// canonical `ValidationIssue` model).
export 'package:appplayer_studio/base.dart'
    show SpecValidator, SpecValidatorImpl;
