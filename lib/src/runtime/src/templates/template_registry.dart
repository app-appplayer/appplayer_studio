/// Template registry, engine, and resolver for MCP UI DSL v1.1 (TM-01)
///
/// Manages template definitions with scope-based resolution and resolves
/// `use` widget instances into their expanded widget trees with parameter substitution.
/// Supports content slots, parameter type validation, and scoped styles.
library template_registry;

import 'dart:convert';

import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show TemplateDefinition;

import '../utils/mcp_logger.dart';

/// Supported parameter types for template parameter validation
enum TemplateParamType {
  /// String parameter
  string,

  /// Integer parameter
  integer,

  /// Double/float parameter
  number,

  /// Boolean parameter
  boolean,

  /// List/array parameter
  list,

  /// Map/object parameter
  map,

  /// Any type (no validation)
  any,
}

/// Definition of a template parameter with type validation support
class TemplateParamDefinition {
  /// Parameter name
  final String name;

  /// Expected parameter type
  final TemplateParamType type;

  /// Whether this parameter is required
  final bool required;

  /// Default value when not provided
  final dynamic defaultValue;

  /// Allowed enum values (if non-null, value must be one of these)
  final List<dynamic>? enumValues;

  /// Custom validator function name (resolved at runtime)
  final String? validator;

  const TemplateParamDefinition({
    required this.name,
    this.type = TemplateParamType.any,
    this.required = false,
    this.defaultValue,
    this.enumValues,
    this.validator,
  });

  /// Create from JSON definition
  factory TemplateParamDefinition.fromJson(
    String name,
    Map<String, dynamic> json,
  ) {
    return TemplateParamDefinition(
      name: name,
      type: _parseParamType(json['type'] as String?),
      required: json['required'] as bool? ?? false,
      defaultValue: json['default'],
      enumValues: (json['enum'] as List?)?.cast<dynamic>(),
      validator: json['validator'] as String?,
    );
  }

  /// Parse a string type name into a TemplateParamType
  static TemplateParamType _parseParamType(String? typeName) {
    if (typeName == null) return TemplateParamType.any;
    switch (typeName.toLowerCase()) {
      case 'string':
        return TemplateParamType.string;
      case 'int':
      case 'integer':
        return TemplateParamType.integer;
      case 'double':
      case 'number':
      case 'float':
        return TemplateParamType.number;
      case 'bool':
      case 'boolean':
        return TemplateParamType.boolean;
      case 'list':
      case 'array':
        return TemplateParamType.list;
      case 'map':
      case 'object':
        return TemplateParamType.map;
      default:
        return TemplateParamType.any;
    }
  }

  /// Validate a value against this parameter definition
  /// Returns null if valid, or an error message if invalid
  String? validate(dynamic value) {
    // Check required
    if (value == null) {
      if (required && defaultValue == null) {
        return 'Parameter "$name" is required';
      }
      return null; // Not required or has default
    }

    // Skip declared-type checks for binding expressions — the literal
    // String `"{{...}}"` is a placeholder for the runtime-resolved
    // value, which is what the declared type describes. Same rationale
    // as `TemplateDefinition.validate` in flutter_mcp_ui_core; spec
    // §9.3.1 does not require strict type rejection, and expressions
    // must be exempt regardless.
    final isExpr = _isBindingExpression(value);

    // Check type
    if (!isExpr && type != TemplateParamType.any && !_isValidType(value)) {
      return 'Parameter "$name" expected type ${type.name}, '
          'got ${value.runtimeType}';
    }

    // Check enum values — expressions resolve at runtime so cannot be
    // compared against the enum list here.
    if (!isExpr && enumValues != null && !enumValues!.contains(value)) {
      return 'Parameter "$name" must be one of: '
          '${enumValues!.join(", ")}';
    }

    return null;
  }

  /// `true` when [value] is a String shaped like a binding expression
  /// (`"{{...}}"`). Placeholder values for runtime-resolved data are
  /// exempted from type / enum checks here — see [validate].
  static bool _isBindingExpression(dynamic value) {
    if (value is! String) return false;
    final open = value.indexOf('{{');
    if (open < 0) return false;
    return value.indexOf('}}', open + 2) > open;
  }

  /// Check if a value matches the expected type
  bool _isValidType(dynamic value) {
    switch (type) {
      case TemplateParamType.string:
        return value is String;
      case TemplateParamType.integer:
        return value is int;
      case TemplateParamType.number:
        return value is num;
      case TemplateParamType.boolean:
        return value is bool;
      case TemplateParamType.list:
        return value is List;
      case TemplateParamType.map:
        return value is Map;
      case TemplateParamType.any:
        return true;
    }
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type.name,
        'required': required,
        if (defaultValue != null) 'default': defaultValue,
        if (enumValues != null) 'enum': enumValues,
        if (validator != null) 'validator': validator,
      };
}

/// Definition of a content slot within a template
class ContentSlotDefinition {
  /// Slot name used for matching
  final String name;

  /// Whether the slot must be filled when using the template
  final bool required;

  /// Fallback widget definition if slot is not filled
  final Map<String, dynamic>? fallback;

  const ContentSlotDefinition({
    required this.name,
    this.required = false,
    this.fallback,
  });

  /// Create from JSON definition
  factory ContentSlotDefinition.fromJson(Map<String, dynamic> json) {
    return ContentSlotDefinition(
      name: json['name'] as String,
      required: json['required'] as bool? ?? false,
      fallback: json['fallback'] as Map<String, dynamic>?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'type': 'slot',
        'name': name,
        'required': required,
        if (fallback != null) 'fallback': fallback,
      };
}

/// Extended template definition with slot, parameter, and style metadata
class ExtendedTemplateDefinition {
  /// Template name
  final String name;

  /// Template content (widget tree definition; DSL key: `content`)
  final Map<String, dynamic> content;

  /// Typed parameter definitions with validation (DSL key: `params`)
  final Map<String, TemplateParamDefinition> paramDefinitions;

  /// Content slot definitions
  final Map<String, ContentSlotDefinition> slotDefinitions;

  /// Whether styles in this template are scoped (CSS-modules style isolation)
  final bool scopedStyles;

  /// Named style bundles per spec § 9.5. Keys are bundle names; values
  /// are style maps consumed by template-internal references such as
  /// `{{styles.<name>}}`. When [scopedStyles] is true the bundle map
  /// is isolated to this template's expansion frame.
  final Map<String, dynamic> styles;

  /// Default parameter values
  final Map<String, dynamic> defaults;

  const ExtendedTemplateDefinition({
    required this.name,
    required this.content,
    this.paramDefinitions = const {},
    this.slotDefinitions = const {},
    this.scopedStyles = false,
    this.styles = const {},
    this.defaults = const {},
  });

  /// Create from JSON definition
  factory ExtendedTemplateDefinition.fromJson(Map<String, dynamic> json) {
    // Parse parameter definitions
    final paramDefs = <String, TemplateParamDefinition>{};
    final paramsJson = json['params'] as Map<String, dynamic>?;
    if (paramsJson != null) {
      for (final entry in paramsJson.entries) {
        if (entry.value is Map<String, dynamic>) {
          paramDefs[entry.key] = TemplateParamDefinition.fromJson(
            entry.key,
            entry.value as Map<String, dynamic>,
          );
        }
      }
    }

    // Parse slot definitions
    final slotDefs = <String, ContentSlotDefinition>{};
    final slotsJson = json['slots'] as List<dynamic>?;
    if (slotsJson != null) {
      for (final slotJson in slotsJson) {
        if (slotJson is Map<String, dynamic>) {
          final slot = ContentSlotDefinition.fromJson(slotJson);
          slotDefs[slot.name] = slot;
        }
      }
    }

    // Parse defaults from param definitions
    final defaults = <String, dynamic>{};
    for (final param in paramDefs.values) {
      if (param.defaultValue != null) {
        defaults[param.name] = param.defaultValue;
      }
    }
    // Overlay explicit defaults
    final explicitDefaults = json['defaults'] as Map<String, dynamic>?;
    if (explicitDefaults != null) {
      defaults.addAll(explicitDefaults);
    }

    return ExtendedTemplateDefinition(
      name: json['name'] as String,
      content: json['content'] as Map<String, dynamic>? ?? {},
      paramDefinitions: paramDefs,
      slotDefinitions: slotDefs,
      scopedStyles: json['scopedStyles'] as bool? ?? false,
      styles: (json['styles'] as Map<String, dynamic>?) ?? const {},
      defaults: defaults,
    );
  }

  /// Validate parameters against definitions
  /// Returns a list of error messages (empty if valid)
  List<String> validateParams(Map<String, dynamic> params) {
    final errors = <String>[];

    for (final paramDef in paramDefinitions.values) {
      final value = params[paramDef.name] ?? paramDef.defaultValue;
      final error = paramDef.validate(value);
      if (error != null) {
        errors.add(error);
      }
    }

    return errors;
  }

  /// Validate that required slots are filled
  /// Returns a list of error messages (empty if valid)
  List<String> validateSlots(Map<String, dynamic> providedSlots) {
    final errors = <String>[];

    for (final slotDef in slotDefinitions.values) {
      if (slotDef.required &&
          !providedSlots.containsKey(slotDef.name) &&
          slotDef.fallback == null) {
        errors.add('Required slot "${slotDef.name}" is not provided');
      }
    }

    return errors;
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'name': name,
        'content': content,
        if (paramDefinitions.isNotEmpty)
          'params': paramDefinitions
              .map((key, value) => MapEntry(key, value.toJson())),
        if (slotDefinitions.isNotEmpty)
          'slots':
              slotDefinitions.values.map((slot) => slot.toJson()).toList(),
        if (scopedStyles) 'scopedStyles': scopedStyles,
        if (styles.isNotEmpty) 'styles': styles,
        if (defaults.isNotEmpty) 'defaults': defaults,
      };
}

/// Scope levels for template registration and resolution
enum TemplateScope {
  /// Framework-provided templates (lowest priority)
  builtIn,

  /// App-level templates defined in application definition
  application,

  /// Screen-level templates (highest priority, cleared on navigation)
  screen,
}

/// Registry for managing and resolving templates with scope-based resolution
class TemplateRegistry {
  /// Scoped template storage: scope -> (name -> template)
  final Map<TemplateScope, Map<String, TemplateDefinition>> _scopedTemplates = {
    TemplateScope.builtIn: {},
    TemplateScope.application: {},
    TemplateScope.screen: {},
  };

  /// Legacy flat map for backward compatibility
  final Map<String, TemplateDefinition> _templates = {};

  /// Extended template definitions with typed params, slots, and scoped styles
  final Map<String, ExtendedTemplateDefinition> _extendedTemplates = {};

  final MCPLogger _logger = MCPLogger('TemplateRegistry');

  // Cache for resolved template instances (name+paramHash → resolved tree)
  final Map<String, Map<String, dynamic>> _instanceCache = {};

  // Cache statistics
  int _cacheHits = 0;
  int _cacheMisses = 0;
  int _definitionCacheHits = 0;
  int _definitionCacheMisses = 0;

  /// Get cache performance statistics
  Map<String, dynamic> getCacheStatistics() {
    return {
      'instanceCacheSize': _instanceCache.length,
      'instanceCacheHits': _cacheHits,
      'instanceCacheMisses': _cacheMisses,
      'definitionCacheHits': _definitionCacheHits,
      'definitionCacheMisses': _definitionCacheMisses,
    };
  }

  /// Compute a deterministic hash key from template name and parameters
  String _computeCacheKey(String templateName, Map<String, dynamic> params) {
    final sortedKeys = params.keys.toList()..sort();
    final paramStr = sortedKeys.map((k) => '$k=${params[k]}').join('&');
    return '$templateName|$paramStr';
  }

  /// Register a template definition (backward-compatible overload)
  void register(TemplateDefinition template) {
    _templates[template.name] = template;
    _scopedTemplates[TemplateScope.application]![template.name] = template;
    _logger.debug('Registered template: ${template.name}');
  }

  /// Register a template at a specific scope (design doc compliant)
  void registerScoped(
    String name,
    Map<String, dynamic> template, {
    TemplateScope scope = TemplateScope.application,
  }) {
    final templateDef = TemplateDefinition.fromJson({
      'name': name,
      ...template,
    });
    _scopedTemplates[scope]![name] = templateDef;
    _templates[name] = templateDef;
    _logger.debug('Registered template "$name" at scope: ${scope.name}');
  }

  /// Register multiple templates from a list
  void registerAll(List<TemplateDefinition> templates) {
    for (final template in templates) {
      register(template);
    }
  }

  /// Register templates from JSON (e.g., from a template library)
  void registerFromJson(List<Map<String, dynamic>> templatesJson) {
    for (final json in templatesJson) {
      register(TemplateDefinition.fromJson(json));
    }
  }

  /// Register built-in framework templates
  void registerBuiltIns() {
    // Built-in templates can be added here as the framework evolves
    _logger.debug('Built-in templates registered');
  }

  /// Unregister a template from all scopes
  void unregister(String name) {
    _templates.remove(name);
    _extendedTemplates.remove(name);
    for (final scope in _scopedTemplates.values) {
      scope.remove(name);
    }
    // Invalidate instance cache entries for this template
    _instanceCache.removeWhere((key, _) => key.startsWith('$name|'));
  }

  /// Get a template by name (backward-compatible)
  TemplateDefinition? get(String name) => _templates[name];

  /// Get a template by name with scope-based resolution
  /// Resolution order: screen -> application -> builtIn
  Map<String, dynamic>? getTemplate(String name) {
    // Search in priority order: screen -> application -> builtIn
    for (final scope in [
      TemplateScope.screen,
      TemplateScope.application,
      TemplateScope.builtIn,
    ]) {
      final template = _scopedTemplates[scope]![name];
      if (template != null) {
        return template.content;
      }
    }
    return null;
  }

  /// Check if a template exists (design doc compliant alias)
  bool hasTemplate(String name) {
    for (final scope in _scopedTemplates.values) {
      if (scope.containsKey(name)) return true;
    }
    return false;
  }

  /// Check if a template exists (backward-compatible)
  bool has(String name) => hasTemplate(name);

  /// Clear templates for a specific scope
  void clearScope(TemplateScope scope) {
    _scopedTemplates[scope]!.clear();
    // Rebuild flat map from remaining scopes
    _templates.clear();
    for (final scopeMap in _scopedTemplates.values) {
      _templates.addAll(scopeMap);
    }
    _logger.debug('Cleared templates for scope: ${scope.name}');
  }

  /// Register an extended template definition with typed params and slots
  void registerExtended(ExtendedTemplateDefinition extTemplate) {
    _extendedTemplates[extTemplate.name] = extTemplate;

    // Also register in the standard registry for backward compatibility
    final templateDef = TemplateDefinition.fromJson({
      'name': extTemplate.name,
      'content': extTemplate.content,
      if (extTemplate.defaults.isNotEmpty) 'defaults': extTemplate.defaults,
    });
    _templates[extTemplate.name] = templateDef;
    _scopedTemplates[TemplateScope.application]![extTemplate.name] =
        templateDef;

    _logger.debug(
      'Registered extended template: ${extTemplate.name} '
      '(params: ${extTemplate.paramDefinitions.length}, '
      'slots: ${extTemplate.slotDefinitions.length}, '
      'scopedStyles: ${extTemplate.scopedStyles})',
    );
  }

  /// Register an extended template from JSON
  void registerExtendedFromJson(Map<String, dynamic> json) {
    registerExtended(ExtendedTemplateDefinition.fromJson(json));
  }

  /// Get an extended template definition by name
  ExtendedTemplateDefinition? getExtended(String name) {
    return _extendedTemplates[name];
  }

  /// Resolve a `use` widget with extended validation (params + slots)
  ///
  /// Falls back to standard resolution if no extended definition exists.
  Map<String, dynamic>? resolveExtended(Map<String, dynamic> useDefinition) {
    final templateName = useDefinition['template'] as String?;
    if (templateName == null) {
      _logger.error('use widget missing template name');
      return null;
    }

    final extTemplate = _extendedTemplates[templateName];
    if (extTemplate == null) {
      // Fall back to standard resolution
      return resolve(useDefinition);
    }

    // Merge defaults with provided params
    final params = <String, dynamic>{};
    params.addAll(extTemplate.defaults);
    if (useDefinition['params'] != null) {
      params.addAll(useDefinition['params'] as Map<String, dynamic>);
    }

    // Validate params with typed definitions
    final paramErrors = extTemplate.validateParams(params);
    if (paramErrors.isNotEmpty) {
      _logger.error(
        'Template "$templateName" parameter validation errors: '
        '${paramErrors.join(", ")}',
      );
      return null;
    }

    // Get and validate slots
    final slots = useDefinition['slots'] as Map<String, dynamic>? ?? {};
    final slotErrors = extTemplate.validateSlots(slots);
    if (slotErrors.isNotEmpty) {
      _logger.error(
        'Template "$templateName" slot validation errors: '
        '${slotErrors.join(", ")}',
      );
      return null;
    }

    // Check instance cache (keyed by name + params, slots excluded)
    final cacheKey = _computeCacheKey(templateName, params);
    final cached = _instanceCache[cacheKey];
    if (cached != null) {
      _cacheHits++;
      return _deepClone(cached);
    }

    // Deep-clone and substitute the template body
    final expanded = _substituteParams(
      _deepClone(extTemplate.content),
      params,
      _resolveSlotFallbacks(slots, extTemplate.slotDefinitions),
    );

    // Add scoped styles marker if enabled
    if (extTemplate.scopedStyles) {
      expanded['_scopedStyles'] = true;
      expanded['_templateName'] = templateName;
    }

    // Store in instance cache
    _cacheMisses++;
    _instanceCache[cacheKey] = _deepClone(expanded);

    return expanded;
  }

  /// Resolve slot contents with fallback support
  Map<String, dynamic> _resolveSlotFallbacks(
    Map<String, dynamic> providedSlots,
    Map<String, ContentSlotDefinition> slotDefinitions,
  ) {
    final resolved = Map<String, dynamic>.from(providedSlots);

    // Fill in fallbacks for unprovided slots
    for (final entry in slotDefinitions.entries) {
      if (!resolved.containsKey(entry.key) && entry.value.fallback != null) {
        resolved[entry.key] = entry.value.fallback;
      }
    }

    return resolved;
  }

  /// Get all registered template names
  List<String> get templateNames => _templates.keys.toList();

  /// Resolve a `use` widget definition into its expanded widget tree
  ///
  /// A `use` widget has the format:
  /// ```json
  /// {
  ///   "type": "use",
  ///   "template": "templateName",
  ///   "params": { ... },
  ///   "slots": { "slotName": { ... widget ... } }
  /// }
  /// ```
  Map<String, dynamic>? resolve(Map<String, dynamic> useDefinition) {
    final templateName = useDefinition['template'] as String?;
    if (templateName == null) {
      _logger.error('use widget missing template name');
      return null;
    }

    final template = _templates[templateName];
    if (template == null) {
      _logger.error('Template not found: $templateName');
      return null;
    }

    // Merge defaults with provided params
    final params = <String, dynamic>{};
    if (template.defaults != null) {
      params.addAll(template.defaults!);
    }
    if (useDefinition['params'] != null) {
      params.addAll(useDefinition['params'] as Map<String, dynamic>);
    }

    // Check instance cache (keyed by name + params, slots excluded)
    final cacheKey = _computeCacheKey(templateName, params);
    final cached = _instanceCache[cacheKey];
    if (cached != null) {
      _cacheHits++;
      return _deepClone(cached);
    }

    // Validate params
    final errors = template.validate(params);
    if (errors.isNotEmpty) {
      _logger.error(
          'Template "$templateName" validation errors: ${errors.join(", ")}');
      return null;
    }

    // Get slot contents
    final slots =
        useDefinition['slots'] as Map<String, dynamic>? ?? {};

    // Deep-clone and substitute the template body
    final expanded = _substituteParams(
      _deepClone(template.content),
      params,
      slots,
    );

    // Store in instance cache
    _cacheMisses++;
    _instanceCache[cacheKey] = _deepClone(expanded);

    return expanded;
  }

  /// Substitute template parameters and slots in a widget tree
  Map<String, dynamic> _substituteParams(
    Map<String, dynamic> tree,
    Map<String, dynamic> params,
    Map<String, dynamic> slots,
  ) {
    final result = <String, dynamic>{};

    for (final entry in tree.entries) {
      result[entry.key] = _substituteValue(entry.value, params, slots);
    }

    return result;
  }

  /// Substitute a single value
  dynamic _substituteValue(
    dynamic value,
    Map<String, dynamic> params,
    Map<String, dynamic> slots,
  ) {
    if (value is String) {
      // Whole-value placeholder (e.g. `"{{layers}}"`) — return the raw
      // parameter value so List / Map / num / bool / null types survive
      // template expansion. Stringifying via `.toString()` would emit
      // `"[a, b]"` / `"{x: 1}"` and downstream factories receiving the
      // result via params would no longer see the original collection
      // shape. Partial placeholders (`"Hello {{name}}"`) still go through
      // `_substituteString` since the result must be a String.
      final whole = _kWholePlaceholder.firstMatch(value);
      if (whole != null) {
        final name = whole.group(1)!;
        if (params.containsKey(name)) return params[name];
      }
      return _substituteString(value, params);
    } else if (value is Map<String, dynamic>) {
      // Check if this is a slot reference
      if (value['type'] == 'slot') {
        final slotName = value['name'] as String?;
        if (slotName != null && slots.containsKey(slotName)) {
          return slots[slotName];
        }
        // Return fallback if defined
        return value['fallback'] ?? value;
      }
      return _substituteParams(value, params, slots);
    } else if (value is List) {
      return value.map((item) => _substituteValue(item, params, slots)).toList();
    }
    return value;
  }

  /// Matches a string that is exactly a single `{{identifier}}` placeholder
  /// with no surrounding literal text. Used by [_substituteValue] to
  /// decide whether to short-circuit into type-preserving substitution.
  static final RegExp _kWholePlaceholder =
      RegExp(r'^\{\{(\w+)\}\}$');

  /// Substitute parameter references in a string
  /// Supports `{{paramName}}` syntax
  String _substituteString(String str, Map<String, dynamic> params) {
    return str.replaceAllMapped(
      RegExp(r'\{\{(\w+)\}\}'),
      (match) {
        final paramName = match.group(1)!;
        final value = params[paramName];
        return value?.toString() ?? match.group(0)!;
      },
    );
  }

  /// Deep clone a map structure
  Map<String, dynamic> _deepClone(Map<String, dynamic> original) {
    final json = jsonEncode(original);
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Clear all registered templates
  void clear() {
    _templates.clear();
    _extendedTemplates.clear();
    for (final scope in _scopedTemplates.values) {
      scope.clear();
    }
    _instanceCache.clear();
    _cacheHits = 0;
    _cacheMisses = 0;
    _definitionCacheHits = 0;
    _definitionCacheMisses = 0;
  }

  /// Dispose and clean up
  void dispose() {
    clear();
  }
}

/// Template engine that resolves template references in widget definition trees
///
/// Works with TemplateRegistry to expand template references recursively.
class TemplateEngine {
  TemplateEngine({
    required TemplateRegistry registry,
    this.maxNestingDepth = 10,
  }) : _registry = registry;

  final TemplateRegistry _registry;
  final MCPLogger _logger = MCPLogger('TemplateEngine');

  /// Maximum allowed nesting depth for recursive template expansion.
  /// Prevents infinite recursion from circular template references.
  final int maxNestingDepth;

  /// Resolve a single `use` widget definition via the registry (per 10-templates.md §6).
  ///
  /// Extracts the template name and overrides from the use-definition map
  /// and delegates to [resolveByName].
  Map<String, dynamic>? resolveUseDefinition(Map<String, dynamic> useDefinition) {
    final templateName = useDefinition['template'] as String?;
    if (templateName == null) return null;

    final overrides = Map<String, dynamic>.from(useDefinition)
      ..remove('type')
      ..remove('template');

    return resolveByName(templateName, overrides: overrides);
  }

  /// Resolve a template reference by name into a widget definition map.
  /// Merges template base with instance overrides.
  Map<String, dynamic> resolveByName(
    String templateName, {
    Map<String, dynamic>? overrides,
  }) {
    final templateBody = _registry.getTemplate(templateName);
    if (templateBody == null) {
      _logger.error('Template not found: $templateName');
      return {'type': 'text', 'text': 'Template not found: $templateName'};
    }

    // Deep clone the template body
    final json = jsonEncode(templateBody);
    final result = jsonDecode(json) as Map<String, dynamic>;

    // Merge overrides if provided
    if (overrides != null) {
      _mergeOverrides(result, overrides);
    }

    return result;
  }

  /// Check whether a value is a template reference (canonical `type: "use"`
  /// per spec §9.6).
  bool isTemplateReference(Map<String, dynamic> definition) {
    return definition['type'] == 'use' && definition['template'] != null;
  }

  /// Expand all template references in a definition tree (recursive)
  ///
  /// Accepts an optional [registry] parameter for compatibility, but
  /// uses the instance registry by default. Throws [StateError] if
  /// nesting exceeds [maxNestingDepth].
  Map<String, dynamic> expandAll(
    Map<String, dynamic> definition, [
    TemplateRegistry? registry,
  ]) {
    return _expandAllWithDepth(definition, 0);
  }

  /// Internal recursive expansion with depth tracking
  Map<String, dynamic> _expandAllWithDepth(
    Map<String, dynamic> definition,
    int currentDepth,
  ) {
    if (currentDepth > maxNestingDepth) {
      _logger.error(
        'Template nesting depth exceeded maximum of $maxNestingDepth',
      );
      throw StateError(
        'Template nesting depth exceeded maximum of $maxNestingDepth. '
        'Check for circular template references.',
      );
    }

    if (isTemplateReference(definition)) {
      // Resolve this template reference
      final expanded = _registry.resolve(definition);
      if (expanded != null) {
        // Recursively expand any nested template references
        return _expandAllWithDepth(expanded, currentDepth + 1);
      }
      return definition;
    }

    // Recursively process all map values
    final result = <String, dynamic>{};
    for (final entry in definition.entries) {
      result[entry.key] = _expandValueWithDepth(entry.value, currentDepth);
    }
    return result;
  }

  /// Expand template references in any value (depth-aware)
  dynamic _expandValueWithDepth(dynamic value, int currentDepth) {
    if (value is Map<String, dynamic>) {
      return _expandAllWithDepth(value, currentDepth);
    } else if (value is List) {
      return value
          .map((item) => _expandValueWithDepth(item, currentDepth))
          .toList();
    }
    return value;
  }

  /// Merge overrides into a template body
  void _mergeOverrides(
    Map<String, dynamic> target,
    Map<String, dynamic> overrides,
  ) {
    for (final entry in overrides.entries) {
      if (entry.value is Map<String, dynamic> &&
          target[entry.key] is Map<String, dynamic>) {
        _mergeOverrides(
          target[entry.key] as Map<String, dynamic>,
          entry.value as Map<String, dynamic>,
        );
      } else {
        target[entry.key] = entry.value;
      }
    }
  }
}
