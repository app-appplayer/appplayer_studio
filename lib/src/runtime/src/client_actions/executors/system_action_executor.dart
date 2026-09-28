/// System action executor for MCP UI DSL v1.1
///
/// Handles system info, clipboard, and notification operations.
library system_action_executor;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../../actions/action_result.dart';
import '../../platform/host_platform.dart';
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
      info['isWeb'] = HostPlatform.isWeb;

      // Get detailed device info
      if (!HostPlatform.isWeb) {
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
            'note': 'HTML clipboard read returns the text flavour; the HTML flavour is not read by this runtime',
          });

        case 'image':
          // Image clipboard requires platform-specific implementation
          // Reporting success for something not performed is the
          // failure this rule exists to stop. `hasContent: false` reads as "the
          // clipboard is empty", which is a different fact from "this runtime
          // cannot look".
          return ActionResult.error(
            'client.clipboard cannot read images in this runtime',
            errorCode: 'UNSUPPORTED',
            errorDetails: <String, dynamic>{'format': 'image'},
          );

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
            'note': 'HTML clipboard write stores the text flavour only',
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

      // No OS notification is posted here, and saying `shown: true` claimed
      // one had been. `UNSUPPORTED` exists for exactly this: a
      // document that asks for a system notification and gets a success it
      // can read as "the user saw it" will not fall back to its in-app
      // `notification` widget, so the message reaches no one.
      return ActionResult.error(
        'client.notification is not implemented by this runtime: no OS-level '
        'notification was posted. Use the in-app `notification` widget, or a '
        'host that provides this capability.',
        errorCode: 'UNSUPPORTED',
        errorDetails: <String, dynamic>{
          'title': title,
          'body': body,
          if (severity != null) 'severity': severity,
          'shown': false,
        },
      );
    } catch (e) {
      return ActionResult.error('Failed to show notification: $e');
    }
  }

  /// Get platform name
  String _getPlatformName() => HostPlatform.name;

  /// Add device-specific information
  Future<void> _addDeviceInfo(Map<String, dynamic> info) async {
    try {
      // Switched on the one platform answer rather than re-reading the host:
      // two readings of the same fact can disagree.
      switch (_getPlatformName()) {
        case 'android':
          final android = await _deviceInfo.androidInfo;
          info['device'] = android.device;
          info['model'] = android.model;
          info['manufacturer'] = android.manufacturer;
          info['osVersion'] = 'Android ${android.version.release}';
          info['sdkInt'] = android.version.sdkInt;
        case 'ios':
          final ios = await _deviceInfo.iosInfo;
          info['device'] = ios.name;
          info['model'] = ios.model;
          info['osVersion'] = 'iOS ${ios.systemVersion}';
          info['isPhysicalDevice'] = ios.isPhysicalDevice;
        case 'macos':
          final macos = await _deviceInfo.macOsInfo;
          info['device'] = macos.computerName;
          info['model'] = macos.model;
          info['osVersion'] = 'macOS ${macos.osRelease}';
          info['arch'] = macos.arch;
        case 'windows':
          final windows = await _deviceInfo.windowsInfo;
          info['device'] = windows.computerName;
          info['osVersion'] =
              'Windows ${windows.majorVersion}.${windows.minorVersion}';
        case 'linux':
          final linux = await _deviceInfo.linuxInfo;
          info['device'] = linux.name;
          info['osVersion'] = linux.prettyName;
      }
    } catch (_) {
      // Device info not available
    }
  }
}
