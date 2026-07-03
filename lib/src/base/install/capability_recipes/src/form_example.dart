/// Example — `mcp_form` as capability tools.
///
/// Shape A: the package already publishes its own MCP tool surface
/// (`FormToolHandler.toolDefinitions` + `handleToolCall`), so the
/// example just maps each declared tool onto a [CapabilityTool]. The
/// host then calls `registerCapabilityTools(registry,
/// capabilityId: 'form', tools: formCapabilityTools())`.
library;

import 'package:mcp_bundle/mcp_bundle.dart' show FormTemplatePort;
import 'package:mcp_form/mcp_form.dart';

import 'capability_tool_pack.dart';

/// Capability id (namespace) for the form tools — exposed names are
/// `form.render`, `form.validate`, ….
const String formCapabilityId = 'form';

/// Build the form capability's tool list from `mcp_form`.
///
/// Pass [templatePort] to control where templates persist. The default is an
/// in-memory port (process-lifetime only). For the Form Builder — template
/// create/manage + document snapshot + history that accumulate per project —
/// pass a `FactBackedFormTemplatePort` so templates live in the project
/// FactGraph (via the kernel), e.g.:
///
/// ```dart
/// final port = await FactBackedFormTemplatePort.hydrate(myKernelFactStore);
/// registerCapabilityTools(registry,
///     capabilityId: 'form', tools: formCapabilityTools(templatePort: port));
/// ```
///
/// Pass [rendererRegistry] to control rendering — in particular to inject the
/// fonts multilingual PDF needs. The default registers the five renderers with
/// no fonts, so non-Latin text (e.g. Korean) renders as `?` in PDF because
/// nothing is embedded. A host loads its own fonts and supplies a registry:
///
/// ```dart
/// final gothic = TrueTypeFont.parse(await File(gothicPath).readAsBytes());
/// formCapabilityTools(
///   templatePort: port,
///   rendererRegistry: standardRendererRegistry(
///     embeddedFont: gothic, fallbackFonts: [gothic]),
/// );
/// ```
List<CapabilityTool> formCapabilityTools({
  FormTemplatePort? templatePort,
  RendererRegistry? rendererRegistry,
}) {
  final handler = _assembleFormToolHandler(templatePort, rendererRegistry);
  return handler.toolDefinitions.map((def) {
    return CapabilityTool(
      // `mcp_form` declares names already prefixed (`form.render`); strip
      // it so the registry does not double the namespace.
      verb: _stripPrefix(def.name, '$formCapabilityId.'),
      description: def.description,
      inputSchema: def.inputSchema,
      invoke: (args) async {
        try {
          return await handler.handleToolCall(
            toolName: def.name,
            arguments: args,
          );
        } on McpToolError catch (e) {
          throw CapabilityToolError(code: e.code, message: e.message);
        }
      },
    );
  }).toList();
}

FormToolHandler _assembleFormToolHandler([
  FormTemplatePort? injected,
  RendererRegistry? rendererRegistry,
]) {
  final templatePort = injected ?? FormTemplatePortImpl();
  final formPort = FormPortImpl(templatePort: templatePort);
  final rendererPort = FormRendererPortImpl(
    // The five bundled renderers must be registered, otherwise every
    // `form.render` / `form.export` returns `render.unsupported_format`.
    // A host injects `standardRendererRegistry(embeddedFont: …)` to make
    // multilingual PDF and global styling reachable; the default has no fonts.
    registry: rendererRegistry ?? standardRendererRegistry(),
    templatePort: templatePort,
  );
  return FormToolHandler(
    formPort: formPort,
    templatePort: templatePort,
    rendererPort: rendererPort,
  );
}

String _stripPrefix(String name, String prefix) =>
    name.startsWith(prefix) ? name.substring(prefix.length) : name;
