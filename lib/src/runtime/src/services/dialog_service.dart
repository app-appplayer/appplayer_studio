import 'package:flutter/material.dart';
import '../runtime/service_registry.dart';
import '../actions/action_handler.dart';
import '../utils/mcp_logger.dart';

/// Service for managing dialogs, bottom sheets, and overlays
class DialogService extends RuntimeService {
  DialogService({super.enableDebugMode});

  static final _logger = MCPLogger('DialogService');

  final List<OverlayEntry> _overlays = [];
  bool _isShowingDialog = false;

  // Use the same navigator key as NavigationActionExecutor
  static GlobalKey<NavigatorState> get navigatorKey =>
      NavigationActionExecutor.navigatorKey;

  /// Shows a dialog with custom content
  Future<T?> show<T>({
    required Widget content,
    String? title,
    List<DialogAction>? actions,
    bool barrierDismissible = true,
    DialogType type = DialogType.normal,
  }) async {
    if (_isShowingDialog) {
      if (enableDebugMode) {
        _logger.debug('Dialog already showing');
      }
      return null;
    }

    _isShowingDialog = true;

    try {
      final context = _getContext();

      Widget dialogContent = content;

      // Wrap content based on type
      switch (type) {
        case DialogType.alert:
          dialogContent = _buildAlertDialog(content, title, actions);
          break;
        case DialogType.confirm:
          dialogContent = _buildConfirmDialog(content, title, actions);
          break;
        case DialogType.input:
          dialogContent = _buildInputDialog(content, title, actions);
          break;
        case DialogType.custom:
        case DialogType.normal:
          if (title != null || actions != null) {
            dialogContent = _buildStandardDialog(content, title, actions);
          } else {
            // Without title/actions the raw content would fill the entire
            // overlay (no bounding surface). Wrap in a standard Dialog so
            // it respects Material sizing + barrier-tap dismissal.
            dialogContent = Dialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 40,
                vertical: 24,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: content,
              ),
            );
          }
          break;
      }

      // Pin the dialog to the runtime's local Navigator (the one owning the
      // pages), not the outermost root Navigator. This keeps dialog lifecycle
      // scoped to the MCP UI surface so popping via
      // `DialogService.navigatorKey` finds the correct route.
      final result = await showDialog<T>(
        context: context,
        useRootNavigator: false,
        barrierDismissible: barrierDismissible,
        builder: (context) => dialogContent,
      );

      return result;
    } finally {
      _isShowingDialog = false;
    }
  }

  /// Shows a simple alert dialog
  Future<void> showAlert({
    required String message,
    String? title,
    String confirmText = 'OK',
  }) async {
    await show(
      content: Text(message),
      title: title,
      type: DialogType.alert,
      actions: [
        DialogAction(
          text: confirmText,
          onPressed: () => Navigator.of(_getContext()).pop(),
        ),
      ],
    );
  }

  /// Shows a confirmation dialog
  Future<bool> showConfirm({
    required String message,
    String? title,
    String confirmText = 'Confirm',
    String cancelText = 'Cancel',
  }) async {
    final result = await show<bool>(
      content: Text(message),
      title: title,
      type: DialogType.confirm,
      actions: [
        DialogAction(
          text: cancelText,
          onPressed: () => Navigator.of(_getContext()).pop(false),
          isDefault: false,
        ),
        DialogAction(
          text: confirmText,
          onPressed: () => Navigator.of(_getContext()).pop(true),
          isDefault: true,
        ),
      ],
    );

    return result ?? false;
  }

  /// Shows an input dialog
  Future<String?> showInput({
    String? title,
    String? hint,
    String? initialValue,
    String confirmText = 'OK',
    String cancelText = 'Cancel',
    TextInputType keyboardType = TextInputType.text,
    int? maxLines = 1,
  }) async {
    final controller = TextEditingController(text: initialValue);

    final result = await show<String>(
      content: TextField(
        controller: controller,
        decoration: InputDecoration(hintText: hint),
        keyboardType: keyboardType,
        maxLines: maxLines,
        autofocus: true,
      ),
      title: title,
      type: DialogType.input,
      actions: [
        DialogAction(
          text: cancelText,
          onPressed: () => Navigator.of(_getContext()).pop(),
        ),
        DialogAction(
          text: confirmText,
          onPressed: () => Navigator.of(_getContext()).pop(controller.text),
          isDefault: true,
        ),
      ],
    );

    controller.dispose();
    return result;
  }

  /// Shows a bottom sheet
  Future<T?> showBottomSheet<T>({
    required Widget content,
    bool isDismissible = true,
    bool enableDrag = true,
    double? height,
    Color? backgroundColor,
    ShapeBorder? shape,
  }) async {
    final context = _getContext();

    return await showModalBottomSheet<T>(
      context: context,
      useRootNavigator: false,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      backgroundColor: backgroundColor,
      shape: shape ??
          const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
      builder: (context) =>
          height != null ? SizedBox(height: height, child: content) : content,
    );
  }

  /// Shows a loading dialog
  void showLoading({
    String? message,
    bool barrierDismissible = false,
  }) {
    show(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message),
          ],
        ],
      ),
      barrierDismissible: barrierDismissible,
    );
  }

  /// Hides the loading dialog
  void hideLoading() {
    if (_isShowingDialog) {
      Navigator.of(_getContext()).pop();
    }
  }

  /// Shows a snackbar
  void showSnackbar({
    required String message,
    SnackbarType type = SnackbarType.info,
    Duration duration = const Duration(seconds: 4),
    SnackBarAction? action,
  }) {
    final context = _getContext();

    Color backgroundColor;
    IconData? icon;

    switch (type) {
      case SnackbarType.success:
        backgroundColor = Colors.green;
        icon = Icons.check_circle;
        break;
      case SnackbarType.error:
        backgroundColor = Colors.red;
        icon = Icons.error;
        break;
      case SnackbarType.warning:
        backgroundColor = Colors.orange;
        icon = Icons.warning;
        break;
      case SnackbarType.info:
        backgroundColor = Theme.of(context).colorScheme.inverseSurface;
        icon = Icons.info;
        break;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: backgroundColor,
        duration: duration,
        action: action,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Shows a custom overlay
  void showOverlay({
    required WidgetBuilder builder,
    bool opaque = false,
    bool maintainState = false,
  }) {
    final context = _getContext();
    final overlay = Overlay.of(context);

    final entry = OverlayEntry(
      opaque: opaque,
      maintainState: maintainState,
      builder: builder,
    );

    _overlays.add(entry);
    overlay.insert(entry);

    if (enableDebugMode) {
      _logger.debug('Showed overlay');
    }
  }

  /// Removes an overlay
  void removeOverlay() {
    if (_overlays.isNotEmpty) {
      final entry = _overlays.removeLast();
      entry.remove();

      if (enableDebugMode) {
        _logger.debug('Removed overlay');
      }
    }
  }

  /// Removes all overlays
  void removeAllOverlays() {
    for (final entry in _overlays) {
      entry.remove();
    }
    _overlays.clear();

    if (enableDebugMode) {
      _logger.debug('Removed all overlays');
    }
  }

  @override
  Future<void> onInitialize(Map<String, dynamic> config) async {
    if (enableDebugMode) {
      _logger.debug('Initialized');
    }
  }

  @override
  Future<void> onDispose() async {
    removeAllOverlays();
  }

  /// Gets the current build context
  /// Uses the navigator's overlay context to ensure dialogs work properly
  /// even when the navigator state might be in transition
  BuildContext _getContext() {
    final navigatorState = navigatorKey.currentState;
    if (navigatorState == null) {
      throw StateError(
          'Navigator not initialized. Make sure navigatorKey is set in MaterialApp');
    }

    // Use the overlay context which is more stable than currentContext
    // This ensures dialogs can be shown even during navigation transitions
    final overlayContext = navigatorState.overlay?.context;
    if (overlayContext == null) {
      // Fallback to current context if overlay is not available
      final context = navigatorKey.currentContext;
      if (context == null) {
        throw StateError('No context available. Navigator might not be ready');
      }
      return context;
    }

    return overlayContext;
  }

  /// Builds a standard dialog layout
  Widget _buildStandardDialog(
    Widget content,
    String? title,
    List<DialogAction>? actions,
  ) {
    return AlertDialog(
      title: title != null ? Text(title) : null,
      content: content,
      actions:
          actions?.map((action) => _buildDialogAction(action)).toList() ?? [],
    );
  }

  /// Builds an alert dialog
  Widget _buildAlertDialog(
    Widget content,
    String? title,
    List<DialogAction>? actions,
  ) {
    return AlertDialog(
      title: title != null ? Text(title) : null,
      content: content,
      actions: actions?.map((action) => _buildDialogAction(action)).toList() ??
          [
            TextButton(
              onPressed: () => Navigator.of(_getContext()).pop(),
              child: const Text('OK'),
            ),
          ],
    );
  }

  /// Builds a confirmation dialog
  Widget _buildConfirmDialog(
    Widget content,
    String? title,
    List<DialogAction>? actions,
  ) {
    return AlertDialog(
      title: title != null ? Text(title) : null,
      content: content,
      actions:
          actions?.map((action) => _buildDialogAction(action)).toList() ?? [],
    );
  }

  /// Builds an input dialog
  Widget _buildInputDialog(
    Widget content,
    String? title,
    List<DialogAction>? actions,
  ) {
    return AlertDialog(
      title: title != null ? Text(title) : null,
      content: SingleChildScrollView(child: content),
      actions:
          actions?.map((action) => _buildDialogAction(action)).toList() ?? [],
    );
  }

  /// Builds a dialog action button
  Widget _buildDialogAction(DialogAction action) {
    final button = action.isDefault
        ? ElevatedButton(
            onPressed: action.onPressed,
            child: Text(action.text),
          )
        : TextButton(
            onPressed: action.onPressed,
            child: Text(action.text),
          );

    return action.isDestructive
        ? Theme(
            data: ThemeData(
              textButtonTheme: TextButtonThemeData(
                style: TextButton.styleFrom(foregroundColor: Colors.red),
              ),
              elevatedButtonTheme: ElevatedButtonThemeData(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              ),
            ),
            child: button,
          )
        : button;
  }
}

/// Types of dialogs
enum DialogType {
  normal,
  alert,
  confirm,
  input,
  custom,
}

/// Types of snackbars
enum SnackbarType {
  info,
  success,
  error,
  warning,
}

/// Represents an action in a dialog
class DialogAction {
  const DialogAction({
    required this.text,
    required this.onPressed,
    this.isDefault = false,
    this.isDestructive = false,
  });

  final String text;
  final VoidCallback onPressed;
  final bool isDefault;
  final bool isDestructive;
}
