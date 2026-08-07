import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Stepper widgets
class StepperWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.6.0/§2.6.20: `binding` shorthand maps to the active step index.
    // Legacy `currentStep` property remains a one-way read-only source.
    final binding = stringOf(properties['binding'], context);
    // `currentStep` is `number | binding`; reading it as `int?` threw on the
    // binding form, which the schema plainly allows.
    final int currentStep = binding != null
        ? ((context.getState<num?>(binding) ??
                context.resolve<num?>(properties['currentStep']) ??
                0)
            .toInt())
        : (context.resolve<num?>(properties['currentStep']) ?? 0).toInt();
    // Spec §2.6.20 canonical `stepperType`; `type` kept as legacy alias.
    final stepperType =
        _parseStepperType(properties['stepperType'] ?? properties['type']) ??
            StepperType.vertical;
    final physics = _parseScrollPhysics(properties['physics']);
    final margin = edgeInsetsOf(properties['margin'], context);

    // Extract steps
    final stepsData = properties['steps'] as List<dynamic>? ?? [];
    final steps =
        stepsData.map((stepData) => _buildStep(stepData, context)).toList();

    // Extract action handlers
    final onStepTapped = actionOf(properties['onStepTapped'], context);
    final onStepContinue =
        actionOf(properties['onStepContinue'], context);
    final onStepCancel = actionOf(properties['onStepCancel'], context);

    Widget stepper = Stepper(
      currentStep: currentStep.clamp(0, steps.isEmpty ? 0 : steps.length - 1),
      type: stepperType,
      physics: physics,
      margin: margin,
      steps: steps,
      onStepTapped: (binding != null || onStepTapped != null)
          ? (step) {
              if (binding != null) {
                context.setValue(binding, step);
              }
              if (onStepTapped != null) {
                final eventContext = context.createChildContext(
                  variables: {
                    'event': {'index': step, 'step': step, 'type': 'stepTapped'},
                  },
                );
                context.actionHandler.execute(onStepTapped, eventContext);
              }
            }
          : null,
      onStepContinue: onStepContinue != null
          ? () {
              context.actionHandler.execute(onStepContinue, context);
            }
          : null,
      onStepCancel: onStepCancel != null
          ? () {
              context.actionHandler.execute(onStepCancel, context);
            }
          : null,
    );

    return applyCommonWrappers(stepper, properties, context);
  }

  Step _buildStep(dynamic stepData, RenderContext context) {
    if (stepData is Map<String, dynamic>) {
      // §2.6.20 documents a step as `{ title, subtitle?, state?, content,
      // isActive? }` and its example writes `"title": "Account"` — a string.
      // A widget is accepted too, for titles that need more than a label.
      // `titleText` predates the spec's shape and still resolves.
      final title = _label(stepData['title'], context) ??
          _label(stepData['titleText'], context) ??
          const Text('');

      final content = _label(stepData['content'], context) ?? Container();

      final subtitle = _label(stepData['subtitle'], context);

      final isActive = stepData['isActive'] as bool? ?? false;
      final state = _parseStepState(stepData['state']);

      return Step(
        title: title,
        content: content,
        subtitle: subtitle,
        isActive: isActive,
        state: state ?? StepState.indexed,
      );
    }

    return Step(
      title: const Text('Step'),
      content: Container(),
    );
  }

  /// A step field that the spec writes as a bare string but that may also
  /// carry a widget. Returns null when the field is absent so the caller
  /// decides the fallback.
  Widget? _label(dynamic value, RenderContext context) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return context.buildWidget(value);
    final text = context.resolve<String?>(value);
    return text == null ? null : Text(text);
  }

  StepperType? _parseStepperType(String? value) {
    switch (value) {
      case 'vertical':
        return StepperType.vertical;
      case 'horizontal':
        return StepperType.horizontal;
      default:
        return null;
    }
  }

  ScrollPhysics? _parseScrollPhysics(String? value) {
    switch (value) {
      case 'bouncing':
        return const BouncingScrollPhysics();
      case 'clamping':
        return const ClampingScrollPhysics();
      case 'never':
        return const NeverScrollableScrollPhysics();
      default:
        return null;
    }
  }

  StepState? _parseStepState(String? value) {
    switch (value) {
      case 'indexed':
        return StepState.indexed;
      case 'editing':
        return StepState.editing;
      case 'complete':
        return StepState.complete;
      case 'disabled':
        return StepState.disabled;
      case 'error':
        return StepState.error;
      default:
        return null;
    }
  }
}
