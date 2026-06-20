import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for form widget.
///
/// The form is hosted by a StatefulWidget so the `GlobalKey<FormState>`
/// survives rebuilds. A new key on each build would remount the
/// subtree, which destroys child `TextEditingController`s mid-typing
/// and causes the "one-character-then-lose-focus" bug. Likewise the
/// submit action reference is captured into context only once per
/// mount so submit buttons below a child-triggered rebuild keep
/// pointing at the right handler.
class FormWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    return _StatefulForm(definition: definition, context: context);
  }
}

class _StatefulForm extends StatefulWidget {
  const _StatefulForm({required this.definition, required this.context});

  final Map<String, dynamic> definition;
  final RenderContext context;

  @override
  State<_StatefulForm> createState() => _StatefulFormState();
}

class _StatefulFormState extends State<_StatefulForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  Map<String, dynamic> _extractProperties() {
    final p = Map<String, dynamic>.from(widget.definition);
    p.remove('type');
    return p;
  }

  Map<String, dynamic>? _currentSubmitAction(
      Map<String, dynamic> properties, Map<String, dynamic>? actions) {
    return (properties['onSubmit'] ?? properties['submit']) as Map<String, dynamic>? ??
        (actions?['onSubmit'] ?? actions?['submit']) as Map<String, dynamic>?;
  }

  AutovalidateMode _resolveAutovalidateMode(String? mode) {
    switch (mode) {
      case 'always':
        return AutovalidateMode.always;
      case 'onUserInteraction':
        return AutovalidateMode.onUserInteraction;
      case 'disabled':
        return AutovalidateMode.disabled;
      default:
        return AutovalidateMode.disabled;
    }
  }

  AutovalidateMode _resolveShowErrorsOn(String mode) {
    switch (mode) {
      case 'change':
        return AutovalidateMode.onUserInteraction;
      case 'blur':
        return AutovalidateMode.onUserInteraction;
      case 'submit':
      default:
        return AutovalidateMode.disabled;
    }
  }

  @override
  Widget build(BuildContext context) {
    final properties = _extractProperties();
    final children = widget.definition['children'] as List<dynamic>? ?? [];
    final actions = widget.definition['actions'] as Map<String, dynamic>?;
    final submitAction = _currentSubmitAction(properties, actions);

    // Refresh the formKey + submit action pointers in the render
    // context on every build so descendants (e.g. submit buttons
    // rendered elsewhere) read the latest values without the key
    // itself changing.
    widget.context.setLocal('_formKey', _formKey);
    if (submitAction != null) {
      widget.context.setLocal('_formSubmitAction', submitAction);
    }

    final showErrorsOn = properties['showErrorsOn'] as String?;
    final mode = showErrorsOn != null
        ? _resolveShowErrorsOn(showErrorsOn)
        : _resolveAutovalidateMode(properties['autovalidateMode']);

    Widget form = Form(
      key: _formKey,
      autovalidateMode: mode,
      onChanged: actions?['onChange'] != null
          ? () => widget.context.handleAction(actions!['onChange'])
          : null,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children
              .map((child) =>
                  widget.context.buildWidget(child as Map<String, dynamic>))
              .toList(),
        ),
      ),
    );

    // When the DSL puts the submit action on `actions.onSubmit`, render
    // a default footer button — matches the spec's implicit submit path.
    if (actions?['onSubmit'] != null) {
      form = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: form),
          ElevatedButton(
            onPressed: () {
              final formState = _formKey.currentState;
              if (formState != null && formState.validate()) {
                formState.save();
                widget.context.handleAction(actions!['onSubmit']);
              }
            },
            child: Text(properties['submitLabel'] ?? 'Submit'),
          ),
        ],
      );
    }

    return form;
  }
}
