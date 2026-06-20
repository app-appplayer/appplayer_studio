import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for NumberStepper widgets (v1.1)
/// Numeric increment/decrement control with +/- buttons
class NumberStepperWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final value = context.resolve<num?>(properties['value']) ?? 0;
    final minValue = context.resolve<num?>(properties['min']);
    final maxValue = context.resolve<num?>(properties['max']);
    final step = context.resolve<num?>(properties['step']) ?? 1;
    final label = context.resolve<String?>(properties['label']);
    final binding = properties['binding'] as String?;
    final onChange = properties['onChange'] ?? properties['change'];
    final color = parseColor(context.resolve(properties['color']), context) ??
        context.themeManager.getColorValue('primary') ??
        Colors.blue;
    final size = context.resolve<String>(properties['size'] ?? 'medium');
    final enabled = context.resolve<bool>(properties['enabled'] ?? true);

    return _NumberStepperWidget(
      value: value.toDouble(),
      minValue: minValue?.toDouble(),
      maxValue: maxValue?.toDouble(),
      step: step.toDouble(),
      label: label,
      binding: binding,
      onChange: onChange as Map<String, dynamic>?,
      color: color,
      size: size,
      enabled: enabled,
      properties: properties,
      context: context,
      factory: this,
    );
  }
}

class _NumberStepperWidget extends StatefulWidget {
  final double value;
  final double? minValue;
  final double? maxValue;
  final double step;
  final String? label;
  final String? binding;
  final Map<String, dynamic>? onChange;
  final Color color;
  final String size;
  final bool enabled;
  final Map<String, dynamic> properties;
  final RenderContext context;
  final WidgetFactory factory;

  const _NumberStepperWidget({
    required this.value,
    this.minValue,
    this.maxValue,
    required this.step,
    this.label,
    this.binding,
    this.onChange,
    required this.color,
    required this.size,
    required this.enabled,
    required this.properties,
    required this.context,
    required this.factory,
  });

  @override
  State<_NumberStepperWidget> createState() => _NumberStepperWidgetState();
}

class _NumberStepperWidgetState extends State<_NumberStepperWidget> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(_NumberStepperWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _value = widget.value;
    }
  }

  void _increment() {
    final newValue = _value + widget.step;
    if (widget.maxValue != null && newValue > widget.maxValue!) return;
    _updateValue(newValue);
  }

  void _decrement() {
    final newValue = _value - widget.step;
    if (widget.minValue != null && newValue < widget.minValue!) return;
    _updateValue(newValue);
  }

  void _updateValue(double newValue) {
    setState(() {
      _value = newValue;
    });

    // Update binding
    if (widget.binding != null) {
      widget.context.stateManager.set(widget.binding!, _value);
    }

    // Execute onChange
    if (widget.onChange != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {'value': _value},
        },
      );
      widget.context.actionHandler.execute(widget.onChange!, eventContext);
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.size == 'small'
        ? 16.0
        : widget.size == 'large'
            ? 28.0
            : 22.0;
    final fontSize = widget.size == 'small'
        ? 14.0
        : widget.size == 'large'
            ? 20.0
            : 16.0;
    final padding = widget.size == 'small'
        ? 4.0
        : widget.size == 'large'
            ? 12.0
            : 8.0;

    final canDecrement =
        widget.minValue == null || _value - widget.step >= widget.minValue!;
    final canIncrement =
        widget.maxValue == null || _value + widget.step <= widget.maxValue!;

    // Format display value
    final displayValue = _value == _value.truncateToDouble()
        ? _value.toInt().toString()
        : _value.toStringAsFixed(2);

    Widget stepper = Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Decrement button
          _buildStepButton(
            Icons.remove,
            canDecrement && widget.enabled ? _decrement : null,
            iconSize,
            padding,
          ),
          // Value display
          Container(
            constraints: BoxConstraints(minWidth: iconSize * 2),
            padding: EdgeInsets.symmetric(horizontal: padding),
            child: Text(
              displayValue,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          // Increment button
          _buildStepButton(
            Icons.add,
            canIncrement && widget.enabled ? _increment : null,
            iconSize,
            padding,
          ),
        ],
      ),
    );

    if (widget.label != null) {
      stepper = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label!,
            style: TextStyle(
              fontSize: fontSize - 2,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 4),
          stepper,
        ],
      );
    }

    return widget.factory
        .applyCommonWrappers(stepper, widget.properties, widget.context);
  }

  Widget _buildStepButton(
    IconData icon,
    VoidCallback? onPressed,
    double iconSize,
    double padding,
  ) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Icon(
          icon,
          size: iconSize,
          color: onPressed != null ? widget.color : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
        ),
      ),
    );
  }
}
