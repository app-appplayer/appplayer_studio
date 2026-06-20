import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../binding/binding_engine.dart';
import '../renderer/render_context.dart';
import '../utils/debounce.dart';
import '../utils/mcp_logger.dart';
import 'validation_engine.dart' show ValidationResult;

/// Base validator class
abstract class Validator {
  /// Validate a value
  ValidationResult validate(dynamic value, RenderContext? context);

  /// Convert to JSON
  Map<String, dynamic> toJson();
}

/// Custom validator that uses expressions for validation
/// according to MCP UI DSL v1.0 specification
class CustomValidator extends Validator {
  final String expression;
  final BindingEngine bindingEngine;
  final String? message;

  CustomValidator({
    required this.expression,
    required this.bindingEngine,
    this.message,
  });

  @override
  ValidationResult validate(dynamic value, RenderContext? context) {
    if (context == null) {
      return ValidationResult.invalid(
        message ?? 'Context required for custom validation',
      );
    }

    try {
      // Create child context with value variable
      final validationContext = context.createChildContext(
        variables: {'value': value},
      );

      // Evaluate expression
      final result = bindingEngine.resolve(expression, validationContext);

      if (result == true) {
        return ValidationResult.valid;
      }

      // If result is a string, use it as error message
      if (result is String && result.isNotEmpty) {
        return ValidationResult.invalid(result);
      }

      return ValidationResult.invalid(
        message ?? 'Validation failed',
      );
    } catch (e) {
      return ValidationResult.invalid(
        'Validation error: ${e.toString()}',
      );
    }
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'custom',
        'expression': expression,
        if (message != null) 'message': message,
      };
}

/// Async validator base class
abstract class AsyncValidator extends Validator {
  final Debouncer _debouncer;
  final MCPLogger _logger = MCPLogger('AsyncValidator');

  AsyncValidator({int debounceMilliseconds = 500})
      : _debouncer = Debouncer(milliseconds: debounceMilliseconds);

  /// Async validation method to implement
  Future<ValidationResult> validateAsync(dynamic value, RenderContext? context);

  @override
  ValidationResult validate(dynamic value, RenderContext? context) {
    // Sync validation always returns pending for async validators
    return ValidationResult.pending('Validating...');
  }

  /// Validate with debouncing
  void validateWithDebounce(
    dynamic value,
    RenderContext? context,
    void Function(ValidationResult) callback,
  ) {
    // Show pending state immediately
    callback(ValidationResult.pending('Validating...'));

    // Debounce the actual validation
    _debouncer.runAsync(() async {
      try {
        final result = await validateAsync(value, context);
        callback(result);
      } catch (e) {
        _logger.error('Async validation error', e);
        callback(ValidationResult.invalid('Validation error: ${e.toString()}'));
      }
    });
  }

  /// Cancel pending validation
  void cancel() {
    _debouncer.cancel();
  }

  void dispose() {
    _debouncer.dispose();
  }
}

/// Remote validator for server-side validation
class RemoteValidator extends AsyncValidator {
  final String endpoint;
  final Map<String, String>? headers;
  final String? fieldName;
  final String? message;

  RemoteValidator({
    required this.endpoint,
    this.headers,
    this.fieldName,
    this.message,
    super.debounceMilliseconds,
  });

  @override
  Future<ValidationResult> validateAsync(
      dynamic value, RenderContext? context) async {
    try {
      // Prepare request body
      final body = <String, dynamic>{};
      if (fieldName != null) {
        body[fieldName!] = value;
      } else {
        body['value'] = value;
      }

      // Make HTTP request
      final response = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              ...?headers,
            },
            body: jsonEncode(body),
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () =>
                throw TimeoutException('Validation request timed out'),
          );

      // Handle response
      if (response.statusCode == 200) {
        try {
          final responseData = jsonDecode(response.body);

          // Check for standard validation response format
          if (responseData is Map<String, dynamic>) {
            final isValid =
                responseData['valid'] ?? responseData['isValid'] ?? true;
            final errorMessage =
                responseData['error'] ?? responseData['message'];

            if (isValid == true) {
              return const ValidationResult(isValid: true);
            } else {
              return ValidationResult.invalid(
                errorMessage?.toString() ?? message ?? 'Validation failed',
                details: responseData['metadata'] as Map<String, dynamic>?,
              );
            }
          }

          // Fallback: treat any 200 response as valid
          return ValidationResult.valid;
        } catch (e) {
          // JSON parsing error
          _logger.error('Failed to parse validation response', e);
          return ValidationResult.invalid(
              message ?? 'Invalid validation response');
        }
      } else if (response.statusCode == 400 || response.statusCode == 422) {
        // Validation failure
        try {
          final errorData = jsonDecode(response.body);
          final errorMessage = errorData['error'] ??
              errorData['message'] ??
              response.reasonPhrase;
          return ValidationResult.invalid(
            errorMessage?.toString() ?? message ?? 'Validation failed',
          );
        } catch (e) {
          return ValidationResult.invalid(
            message ?? 'Validation failed: ${response.reasonPhrase}',
          );
        }
      } else {
        // Server error
        return ValidationResult.invalid(
          message ?? 'Server error: ${response.statusCode}',
        );
      }
    } catch (e) {
      _logger.error('Remote validation error', e);

      if (e is TimeoutException) {
        return ValidationResult.invalid(
            message ?? 'Validation request timed out');
      } else if (e is http.ClientException) {
        return ValidationResult.invalid(
            message ?? 'Network error during validation');
      } else {
        return ValidationResult.invalid(
          message ?? 'Validation error: ${e.toString()}',
        );
      }
    }
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'remote',
        'endpoint': endpoint,
        if (headers != null) 'headers': headers,
        if (fieldName != null) 'fieldName': fieldName,
        if (message != null) 'message': message,
      };
}

/// Composite async validator that combines multiple validators
class CompositeAsyncValidator extends AsyncValidator {
  final List<AsyncValidator> validators;
  final bool stopOnFirstError;

  CompositeAsyncValidator({
    required this.validators,
    this.stopOnFirstError = true,
    super.debounceMilliseconds,
  });

  @override
  Future<ValidationResult> validateAsync(
      dynamic value, RenderContext? context) async {
    final errors = <String>[];

    for (final validator in validators) {
      final result = await validator.validateAsync(value, context);

      if (!result.isValid) {
        errors.add(result.message ?? 'Validation failed');

        if (stopOnFirstError) {
          return ValidationResult.invalid(errors.first);
        }
      }
    }

    if (errors.isEmpty) {
      return ValidationResult.valid;
    }

    return ValidationResult.invalid(errors.join(', '));
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'composite_async',
        'validators': validators.map((v) => v.toJson()).toList(),
        'stopOnFirstError': stopOnFirstError,
      };

  @override
  void dispose() {
    super.dispose();
    for (final validator in validators) {
      validator.dispose();
    }
  }
}

/// Validation state for managing async validation
class ValidationState extends ChangeNotifier {
  final Map<String, ValidationResult> _results = {};
  final Map<String, AsyncValidator> _validators = {};

  /// Get validation result for a field
  ValidationResult? getResult(String fieldName) => _results[fieldName];

  /// Check if field is valid
  bool isFieldValid(String fieldName) => _results[fieldName]?.isValid ?? true;

  /// Check if field is pending validation
  bool isFieldPending(String fieldName) =>
      _results[fieldName]?.isPending ?? false;

  /// Get error for field
  String? getFieldError(String fieldName) => _results[fieldName]?.message;

  /// Validate a field
  void validateField(
    String fieldName,
    dynamic value,
    AsyncValidator validator,
    RenderContext? context,
  ) {
    // Store validator
    _validators[fieldName] = validator;

    // Start validation
    validator.validateWithDebounce(
      value,
      context,
      (result) {
        _results[fieldName] = result;
        notifyListeners();
      },
    );
  }

  /// Clear validation for a field
  void clearField(String fieldName) {
    _results.remove(fieldName);
    _validators[fieldName]?.cancel();
    _validators.remove(fieldName);
    notifyListeners();
  }

  /// Clear all validations
  void clear() {
    _results.clear();
    for (final validator in _validators.values) {
      validator.cancel();
    }
    _validators.clear();
    notifyListeners();
  }

  /// Check if all fields are valid
  bool get isValid {
    return _results.values
        .every((result) => result.isValid || result.isPending);
  }

  /// Check if any field is pending
  bool get hasPendingValidations {
    return _results.values.any((result) => result.isPending);
  }

  @override
  void dispose() {
    for (final validator in _validators.values) {
      validator.dispose();
    }
    super.dispose();
  }
}

/// Form validation mixin for widgets
mixin FormValidationMixin<T extends StatefulWidget> on State<T> {
  final ValidationState _validationState = ValidationState();

  ValidationState get validationState => _validationState;

  /// Validate a field
  void validateField(
    String fieldName,
    dynamic value,
    AsyncValidator validator, [
    RenderContext? context,
  ]) {
    _validationState.validateField(fieldName, value, validator, context);
  }

  /// Clear field validation
  void clearFieldValidation(String fieldName) {
    _validationState.clearField(fieldName);
  }

  /// Clear all validations
  void clearValidations() {
    _validationState.clear();
  }

  /// Check if form is valid
  bool get isFormValid => _validationState.isValid;

  /// Check if form has pending validations
  bool get hasPendingValidations => _validationState.hasPendingValidations;

  @override
  void dispose() {
    _validationState.dispose();
    super.dispose();
  }
}
