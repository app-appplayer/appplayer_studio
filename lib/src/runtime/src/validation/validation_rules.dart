// ValidationRuleType is defined in validation_engine.dart (single source of truth)

/// Property keys for MCP UI DSL v1.0
class PropertyKeys {
  // Widget properties
  static const String type = 'type';
  static const String content = 'content';
  static const String label = 'label';
  static const String value = 'value';
  static const String binding = 'binding';
  static const String children = 'children';
  static const String items = 'items';
  static const String direction = 'direction';
  static const String alignment = 'alignment';
  static const String spacing = 'spacing';
  static const String padding = 'padding';
  static const String margin = 'margin';
  static const String width = 'width';
  static const String height = 'height';
  static const String style = 'style';
  static const String theme = 'theme';

  // Event handler property keys (on + PascalCase per v1.0 §9)
  static const String onTap = 'onTap';
  static const String onDoubleTap = 'onDoubleTap';
  static const String onRightClick = 'onRightClick';
  static const String onLongPress = 'onLongPress';
  static const String onChange = 'onChange';
  static const String onFocus = 'onFocus';
  static const String onBlur = 'onBlur';
  static const String onSubmit = 'onSubmit';
  static const String onItemClick = 'onItemClick';
  static const String onIndexChange = 'onIndexChange';

  // Legacy event handler aliases (backward compatibility)
  static const String click = 'click';
  static const String change = 'change';
  static const String focus = 'focus';
  static const String blur = 'blur';
  static const String submit = 'submit';
  static const String doubleClick = 'double-click';
  static const String rightClick = 'right-click';
  static const String longPress = 'long-press';

  // Action properties
  static const String action = 'action';
  static const String tool = 'tool';
  static const String params = 'params';
  static const String args = 'args';
  static const String route = 'route';
  static const String uri = 'uri';
  static const String method = 'method';
  static const String target = 'target';
  static const String data = 'data';
}
