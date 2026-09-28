/// Host-level form + ingest capabilities.
///
/// Exposes `mcp_form` (`form.*`) and `mcp_ingest` (`ingest.*`) as general
/// host tools on the shared [HostToolRegistry], so any built-in (ops, …)
/// or bundle app uses one engine instead of owning its own (parity rule).
library;

import 'dart:io';
import 'dart:convert' show jsonEncode;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_form/mcp_form.dart'
    show RendererRegistry, TrueTypeFont, standardRendererRegistry;
import 'package:mcp_ingest/mcp_ingest.dart';

import 'capability_recipes/capability_recipes.dart'
    show
        CapabilityTool,
        CapabilityToolError,
        formCapabilityId,
        formCapabilityTools,
        registerCapabilityTools;
import 'form_spec_vocab.dart' show validateTemplateVocabulary;

/// Register `form.<verb>` for every tool `mcp_form` declares, via the
/// vendored `capability_tools` recipe (the canonical form wiring — the same
/// assembly any host uses, so a bundle drives `form.*` identically anywhere).
///
/// [templatePort] controls where templates persist. The default is the
/// engine's in-memory port (process-lifetime — the unbound state). The Form
/// Builder rebinds this registration with a `FactBackedFormTemplatePort`
/// hydrated from its bound project's FactGraph (see
/// `form_capability_store.dart::bindFormCapabilityTemplates`).
///
/// Re-registration is made explicit: `HostToolRegistry.registerExposed` does
/// NOT replace (the endpoint throws "Tool ... already exists" — live-verified
/// 2026-07-03), so each verb is `unregisterExposed`d first. First
/// registration is a no-op removal.
List<String> registerFormCapability(
  HostToolRegistry registry, {
  FormTemplatePort? templatePort,
}) {
  final tools = [
    for (final tool in formCapabilityTools(
      templatePort: templatePort,
      // CJK PDF fidelity: inject a system Korean-capable TrueType through
      // the engine's renderer seam (subsetting keeps the PDF small). Without
      // it every Hangul glyph prints '?'.
      rendererRegistry: _hostRendererRegistry(),
    ))
      tool.verb == 'save_template' ? withFormVocabularyGate(tool) : tool,
  ];
  for (final tool in tools) {
    registry.unregisterExposed(bundleId: formCapabilityId, rawName: tool.verb);
  }
  return registerCapabilityTools(
    registry,
    capabilityId: formCapabilityId,
    tools: tools,
  );
}

/// The registry every `form.*` registration renders with: the five bundled
/// renderers plus the host's CJK font on both the primary-embed and fallback
/// seams (primary covers Hangul-only documents; fallback covers mixed
/// Latin/Hangul runs).
RendererRegistry _hostRendererRegistry() {
  final cjk = _systemCjkFont();
  return standardRendererRegistry(
    embeddedFont: cjk,
    fallbackFonts: cjk == null ? const [] : [cjk],
  );
}

TrueTypeFont? _cachedCjkFont;
bool _cjkFontLoadAttempted = false;

/// First present system font that covers Hangul — parsed once per process.
TrueTypeFont? _systemCjkFont() {
  if (_cjkFontLoadAttempted) return _cachedCjkFont;
  _cjkFontLoadAttempted = true;
  const candidates = <String>[
    '/System/Library/Fonts/Supplemental/AppleGothic.ttf', // macOS
    '/System/Library/Fonts/Supplemental/AppleMyungjo.ttf', // macOS
    'C:/Windows/Fonts/malgun.ttf', // Windows
    '/usr/share/fonts/truetype/nanum/NanumGothic.ttf', // Linux
  ];
  for (final path in candidates) {
    try {
      final file = File(path);
      if (!file.existsSync()) continue;
      _cachedCjkFont = TrueTypeFont.parse(file.readAsBytesSync());
      return _cachedCjkFont;
    } catch (_) {
      // Unparseable candidate — try the next; null keeps latin-only PDFs.
    }
  }
  return null;
}

/// Vocabulary gate on `form.save_template`: out-of-spec enumerable values
/// (block type, align, overflow, placement anchor) are REJECTED with a
/// message listing the allowed values — so an LLM (or a person) learns
/// what went wrong instead of persisting a value viewers can't render.
/// Vocabulary source: `form_spec_vocab.dart` (derived from the published
/// engine types until `specs-pub/form` lands).
CapabilityTool withFormVocabularyGate(CapabilityTool tool) {
  return CapabilityTool(
    verb: tool.verb,
    description: tool.description,
    inputSchema: tool.inputSchema,
    invoke: (args) {
      final template = (args['template'] as Map?)?.cast<String, dynamic>();
      if (template != null) {
        final violations = validateTemplateVocabulary(template);
        if (violations.isNotEmpty) {
          throw CapabilityToolError(
            code: 'form.spec_violation',
            message:
                'Template rejected — out-of-spec values:\n'
                '${violations.join('\n')}',
          );
        }
      }
      return tool.invoke(args);
    },
  );
}

/// Register `ingest.run` (shape B — wrap the `IngestPipeline` runtime).
List<String> registerIngestCapability(HostToolRegistry registry) {
  final pipeline = IngestPipeline.defaults();
  return <String>[
    registry.registerExposed(
      bundleId: 'ingest',
      rawName: 'run',
      description: 'Ingest a text document into normalized chunks.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'content': <String, dynamic>{
            'type': 'string',
            'description': 'Raw document text to ingest.',
          },
          'filename': <String, dynamic>{'type': 'string'},
          'mimeType': <String, dynamic>{
            'type': 'string',
            'default': 'text/plain',
          },
        },
        'required': <String>['content'],
      },
      handler: (args) async {
        try {
          final content = args['content'];
          if (content is! String || content.isEmpty) {
            return _result(<String, dynamic>{
              'ok': false,
              'code': 'ingest.bad_input',
              'error': 'content (non-empty string) is required',
            }, isError: true);
          }
          final input = IngestInput.fromString(
            content,
            filename: args['filename'] as String?,
            mimeType: (args['mimeType'] as String?) ?? 'text/plain',
          );
          final out = await pipeline.ingest(input, IngestOptions.defaults);
          if (out.error != null) {
            return _result(<String, dynamic>{
              'ok': false,
              'code': 'ingest.failed',
              'error': out.error.toString(),
            }, isError: true);
          }
          return _result(<String, dynamic>{
            'ok': true,
            'count': out.chunks.length,
            // Return chunk texts so consumers (e.g. a knowledge ingest that
            // extracts facts) can use them — not just the count.
            'chunks': <Map<String, dynamic>>[
              for (final c in out.chunks) <String, dynamic>{'text': c.text},
            ],
            'warnings': out.warnings,
          }, isError: false);
        } catch (e) {
          return _result(<String, dynamic>{
            'ok': false,
            'code': 'ingest.error',
            'error': e.toString(),
          }, isError: true);
        }
      },
    ),
  ];
}

KernelToolResult _result(Object? value, {required bool isError}) {
  return KernelToolResult(
    content: <KernelContent>[KernelTextContent(text: jsonEncode(value))],
    isError: isError,
  );
}
