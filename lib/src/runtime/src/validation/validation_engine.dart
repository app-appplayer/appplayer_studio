import '../utils/mcp_logger.dart';

/// Validation result per MCP UI DSL v1.1 spec (feat-runtime/17-validation.md §3.3)
class ValidationResult {
  final bool isValid;
  final String? message;
  final Map<String, dynamic>? details;

  const ValidationResult({
    required this.isValid,
    this.message,
    this.details,
  });

  static const ValidationResult valid = ValidationResult(isValid: true);

  factory ValidationResult.invalid(String message,
      {Map<String, dynamic>? details}) {
    return ValidationResult(
      isValid: false,
      message: message,
      details: details,
    );
  }

  /// Create a pending result for async validation in progress.
  /// Represented as invalid with details: {'isPending': true}.
  factory ValidationResult.pending([String? message]) {
    return ValidationResult(
      isValid: false,
      message: message,
      details: const {'isPending': true},
    );
  }

  /// Whether this result represents an in-progress async validation.
  bool get isPending => details?['isPending'] == true;
}

/// Validation rule types
enum ValidationRuleType {
  required,
  minLength,
  maxLength,
  pattern,
  email,
  url,
  min,
  max,
  oneOf,
  match,
  custom,
  async,
}

/// Validation rule
class ValidationRule {
  final ValidationRuleType type;
  final dynamic value;
  final String? message;

  const ValidationRule({
    required this.type,
    this.value,
    this.message,
  });
}

/// Validation engine for MCP UI DSL v1.0
class ValidationEngine {
  static final MCPLogger _logger = MCPLogger('ValidationEngine');

  /// Parse validation definition from MCP UI DSL v1.0 format
  static List<ValidationRule> parseValidation(dynamic validation) {
    if (validation == null) return [];

    final rules = <ValidationRule>[];

    // Handle array format (newer spec)
    if (validation is List) {
      for (final rule in validation) {
        if (rule is Map<String, dynamic>) {
          final type = rule['type'] as String?;
          final message = rule['message'] as String?;

          switch (type) {
            case 'required':
              rules.add(ValidationRule(
                type: ValidationRuleType.required,
                message: message ?? 'This field is required',
              ));
              break;
            case 'email':
              rules.add(ValidationRule(
                type: ValidationRuleType.email,
                message: message ?? 'Invalid email address',
              ));
              break;
            case 'minLength':
              rules.add(ValidationRule(
                type: ValidationRuleType.minLength,
                value: rule['value'] ?? rule['minLength'],
                message: message ??
                    'Minimum length is ${rule['value'] ?? rule['minLength']}',
              ));
              break;
            case 'maxLength':
              rules.add(ValidationRule(
                type: ValidationRuleType.maxLength,
                value: rule['value'] ?? rule['maxLength'],
                message: message ??
                    'Maximum length is ${rule['value'] ?? rule['maxLength']}',
              ));
              break;
            case 'pattern':
              rules.add(ValidationRule(
                type: ValidationRuleType.pattern,
                value: rule['value'] ?? rule['pattern'],
                message: message ?? 'Invalid format',
              ));
              break;
            case 'min':
              rules.add(ValidationRule(
                type: ValidationRuleType.min,
                value: rule['value'] ?? rule['min'],
                message: message ??
                    'Minimum value is ${rule['value'] ?? rule['min']}',
              ));
              break;
            case 'max':
              rules.add(ValidationRule(
                type: ValidationRuleType.max,
                value: rule['value'] ?? rule['max'],
                message: message ??
                    'Maximum value is ${rule['value'] ?? rule['max']}',
              ));
              break;
            case 'url':
              rules.add(ValidationRule(
                type: ValidationRuleType.url,
                message: message ?? 'Invalid URL',
              ));
              break;
            case 'oneOf':
              rules.add(ValidationRule(
                type: ValidationRuleType.oneOf,
                value: rule['value'] ?? rule['oneOf'] ?? rule['values'],
                message: message ?? 'Must be one of the allowed values',
              ));
              break;
            case 'match':
              rules.add(ValidationRule(
                type: ValidationRuleType.match,
                value: rule['field'],
                message: message ?? 'Fields do not match',
              ));
              break;
            case 'custom':
              rules.add(ValidationRule(
                type: ValidationRuleType.custom,
                value: rule['value'] ?? rule['validator'],
                message: message ?? 'Custom validation failed',
              ));
              break;
            case 'async':
              rules.add(ValidationRule(
                type: ValidationRuleType.async,
                value: rule['value'] ?? rule['validator'] ?? rule['url'],
                message: message ?? 'Async validation failed',
              ));
              break;
          }
        }
      }
      return rules;
    }

    // Reject legacy object format - MCP UI DSL v1.0 only supports array format
    if (validation is! Map<String, dynamic>) return [];

    // Log warning about legacy format usage and return empty rules
    _logger.warning(
        'Legacy validation format detected. MCP UI DSL v1.0 only supports array format for validation rules.');
    return [];
  }

  /// Validate a value against rules
  static ValidationResult validate(dynamic value, List<ValidationRule> rules) {
    for (final rule in rules) {
      final result = _validateRule(value, rule);
      if (!result.isValid) {
        return result;
      }
    }
    return ValidationResult.valid;
  }

  /// Validate a single rule
  static ValidationResult _validateRule(dynamic value, ValidationRule rule) {
    switch (rule.type) {
      case ValidationRuleType.required:
        if (value == null || (value is String && value.isEmpty)) {
          return ValidationResult.invalid(rule.message!);
        }
        break;

      case ValidationRuleType.minLength:
        if (value is String && value.length < (rule.value as int)) {
          return ValidationResult.invalid(rule.message!);
        }
        break;

      case ValidationRuleType.maxLength:
        if (value is String && value.length > (rule.value as int)) {
          return ValidationResult.invalid(rule.message!);
        }
        break;

      case ValidationRuleType.pattern:
        if (value is String) {
          final regex = RegExp(rule.value as String);
          if (!regex.hasMatch(value)) {
            return ValidationResult.invalid(rule.message!);
          }
        }
        break;

      case ValidationRuleType.email:
        if (value is String) {
          final emailRegex = RegExp(
            r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
          );
          if (!emailRegex.hasMatch(value)) {
            return ValidationResult.invalid(rule.message!);
          }
        }
        break;

      case ValidationRuleType.url:
        if (value is String) {
          final urlRegex = RegExp(
            r'^https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)$',
          );
          if (!urlRegex.hasMatch(value)) {
            return ValidationResult.invalid(rule.message!);
          }
        }
        break;

      case ValidationRuleType.min:
        if (value is num && value < (rule.value as num)) {
          return ValidationResult.invalid(rule.message!);
        }
        break;

      case ValidationRuleType.max:
        if (value is num && value > (rule.value as num)) {
          return ValidationResult.invalid(rule.message!);
        }
        break;

      case ValidationRuleType.oneOf:
        if (rule.value is List && !rule.value.contains(value)) {
          return ValidationResult.invalid(rule.message!);
        }
        break;

      case ValidationRuleType.match:
        // Match validation requires form context — handled in validateForm
        break;

      case ValidationRuleType.custom:
        // Custom validation would be handled by the widget itself
        break;

      case ValidationRuleType.async:
        // Async validation is handled by validateAsync method
        break;
    }

    return ValidationResult.valid;
  }

  /// Create a Flutter validator function from rules
  static String? Function(String?) createFlutterValidator(
      List<ValidationRule> rules) {
    return (String? value) {
      final result = validate(value, rules);
      return result.isValid ? null : result.message;
    };
  }

  /// Validate form data
  ///
  /// Handles `match` rules by comparing the field value against
  /// the referenced field's value within [formData].
  static Map<String, ValidationResult> validateForm(
    Map<String, dynamic> formData,
    Map<String, List<ValidationRule>> fieldRules,
  ) {
    final results = <String, ValidationResult>{};

    for (final entry in fieldRules.entries) {
      final fieldName = entry.key;
      final rules = entry.value;
      final value = formData[fieldName];

      // First run standard validation
      final result = validate(value, rules);
      if (!result.isValid) {
        results[fieldName] = result;
        continue;
      }

      // Then check match rules that require form context
      for (final rule in rules) {
        if (rule.type == ValidationRuleType.match) {
          final refField = rule.value as String?;
          if (refField != null && formData[refField] != value) {
            results[fieldName] = ValidationResult.invalid(rule.message!);
            break;
          }
        }
      }

      results.putIfAbsent(fieldName, () => ValidationResult.valid);
    }

    return results;
  }

  /// Check if all form fields are valid
  static bool isFormValid(Map<String, ValidationResult> results) {
    return results.values.every((result) => result.isValid);
  }

  /// Validate a value asynchronously using a custom async validator.
  ///
  /// Runs synchronous [rules] first, then invokes [asyncValidator] if
  /// sync validation passes. Supports MCP tool-based server-side validation.
  static Future<ValidationResult> validateAsync(
    dynamic value,
    List<ValidationRule> rules, {
    required Future<ValidationResult> Function(dynamic value) asyncValidator,
  }) async {
    // Run sync rules first
    final syncResult = validate(value, rules);
    if (!syncResult.isValid) return syncResult;

    // Run async validation
    return asyncValidator(value);
  }
}
