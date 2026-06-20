/// System action executor for MCP UI DSL v1.1
///
/// Handles system info, clipboard, and notification operations.
library system_action_executor;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../../actions/action_result.dart';
import '../../renderer/render_context.dart';

/// Executes system-related client actions
class SystemActionExecutor {
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  /// Get system information
  Future<ActionResult> getSystemInfo(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    try {
      final properties = action['properties'] as List<dynamic>?;
      final info = <String, dynamic>{};

      // Basic platform info
      info['platform'] = _getPlatformName();
      info['isWeb'] = kIsWeb;

      // Get detailed device info
      if (!kIsWeb) {
        await _addDeviceInfo(info);
      }

      // Add locale info
      info['locale'] = PlatformDispatcher.instance.locale.toString();
      info['locales'] = PlatformDispatcher.instance.locales
          .map((l) => l.toString())
          .toList();

      // Filter properties if specified
      if (properties != null && properties.isNotEmpty) {
        final filtered = <String, dynamic>{};
        for (final prop in properties) {
          final key = prop.toString();
          if (info.containsKey(key)) {
            filtered[key] = info[key];
          }
        }
        return ActionResult.success(data: filtered);
      }

      return ActionResult.success(data: info);
    } catch (e) {
      return ActionResult.error('Failed to get system info: $e');
    }
  }

  /// Read from clipboard
  /// Supports text, html, and image formats via the 'format' parameter
  Future<ActionResult> clipboardRead(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    try {
      final format = action['format'] as String? ?? 'text';

      switch (format) {
        case 'html':
          // HTML clipboard access is platform-dependent
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          return ActionResult.success(data: {
            'text': data?.text,
            'hasContent': data?.text != null,
            'format': 'html',
            'note': 'HTML clipboard read uses text fallback; full HTML requires platform-specific implementation',
          });

        case 'image':
          // Image clipboard requires platform-specific implementation
          return ActionResult.success(data: {
            'hasContent': false,
            'format': 'image',
            'note': 'Image clipboard read requires platform-specific implementation',
          });

        case 'text':
        default:
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          if (data == null || data.text == null) {
            return ActionResult.success(data: {
              'text': null,
              'hasContent': false,
              'format': 'text',
            });
          }
          return ActionResult.success(data: {
            'text': data.text,
            'hasContent': true,
            'format': 'text',
          });
      }
    } catch (e) {
      return ActionResult.error('Failed to read clipboard: $e');
    }
  }

  /// Write to clipboard
  /// Accepts both 'content' (spec) and 'text' (impl) parameters (CA-04)
  /// Supports text, html, and image formats via the 'format' parameter
  Future<ActionResult> clipboardWrite(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    try {
      final format = action['format'] as String? ?? 'text';
      final content = action['content'] as String? ??
          action['text'] as String?;

      switch (format) {
        case 'html':
          if (content == null) {
            return ActionResult.error('Content parameter is required');
          }
          // Write HTML content as text (full HTML clipboard requires platform channel)
          await Clipboard.setData(ClipboardData(text: content));
          return ActionResult.success(data: {
            'success': true,
            'text': content,
            'format': 'html',
            'note': 'HTML clipboard write uses text fallback; full HTML requires platform-specific implementation',
          });

        case 'image':
          return ActionResult.error(
            'Image clipboard write requires platform-specific setup',
          );

        case 'text':
        default:
          if (content == null) {
            return ActionResult.error('Content parameter is required');
          }
          await Clipboard.setData(ClipboardData(text: content));
          return ActionResult.success(data: {
            'success': true,
            'text': content,
            'format': 'text',
          });
      }
    } catch (e) {
      return ActionResult.error('Failed to write to clipboard: $e');
    }
  }

  /// Show a notification (platform-dependent)
  /// Accepts both spec naming ('message', 'severity') and impl naming ('title', 'body') (CA-05)
  Future<ActionResult> showNotification(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    try {
      final title = action['title'] as String? ?? 'Notification';
      final body = action['message'] as String? ??
          action['body'] as String? ?? '';
      final severity = action['severity'] as String?;

      // For now, just return success with the notification data
      // Actual notification implementation would require platform-specific setup
      return ActionResult.success(data: {
        'title': title,
        'body': body,
        if (severity != null) 'severity': severity,
        'shown': true,
        'note': 'Platform notification requires additional setup',
      });
    } catch (e) {
      return ActionResult.error('Failed to show notification: $e');
    }
  }

  /// Get platform name
  String _getPlatformName() {
    if (kIsWeb) return 'web';

    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isFuchsia) return 'fuchsia';

    return 'unknown';
  }

  /// Add device-specific information
  Future<void> _addDeviceInfo(Map<String, dynamic> info) async {
    try {
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        info['device'] = android.device;
        info['model'] = android.model;
        info['manufacturer'] = android.manufacturer;
        info['osVersion'] = 'Android ${android.version.release}';
        info['sdkInt'] = android.version.sdkInt;
      } else if (Platform.isIOS) {
        final ios = await _deviceInfo.iosInfo;
        info['device'] = ios.name;
        info['model'] = ios.model;
        info['osVersion'] = 'iOS ${ios.systemVersion}';
        info['isPhysicalDevice'] = ios.isPhysicalDevice;
      } else if (Platform.isMacOS) {
        final macos = await _deviceInfo.macOsInfo;
        info['device'] = macos.computerName;
        info['model'] = macos.model;
        info['osVersion'] = 'macOS ${macos.osRelease}';
        info['arch'] = macos.arch;
      } else if (Platform.isWindows) {
        final windows = await _deviceInfo.windowsInfo;
        info['device'] = windows.computerName;
        info['osVersion'] =
            'Windows ${windows.majorVersion}.${windows.minorVersion}';
      } else if (Platform.isLinux) {
        final linux = await _deviceInfo.linuxInfo;
        info['device'] = linux.name;
        info['osVersion'] = linux.prettyName;
      }
    } catch (_) {
      // Device info not available
    }
  }
}
