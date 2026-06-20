/// HTTP action executor for MCP UI DSL v1.1
///
/// Handles HTTP requests (GET, POST, PUT, DELETE).
library http_action_executor;

import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../actions/action_result.dart';
import '../../renderer/render_context.dart';

/// Executes HTTP request client actions
class HttpActionExecutor {
  /// Make an HTTP request
  Future<ActionResult> request(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    try {
      final url = action['url'] as String?;
      if (url == null) {
        return ActionResult.error('URL parameter is required');
      }

      final method = (action['method'] as String? ?? 'GET').toUpperCase();
      final headers = _parseHeaders(action['headers']);
      final body = action['body'];
      final timeout = action['timeout'] as int? ?? 30000;

      final uri = Uri.parse(url);
      final client = http.Client();

      try {
        http.Response response;

        switch (method) {
          case 'GET':
            response = await client
                .get(uri, headers: headers)
                .timeout(Duration(milliseconds: timeout));
            break;

          case 'POST':
            response = await client
                .post(
                  uri,
                  headers: headers,
                  body: _encodeBody(body, headers),
                )
                .timeout(Duration(milliseconds: timeout));
            break;

          case 'PUT':
            response = await client
                .put(
                  uri,
                  headers: headers,
                  body: _encodeBody(body, headers),
                )
                .timeout(Duration(milliseconds: timeout));
            break;

          case 'DELETE':
            response = await client
                .delete(uri, headers: headers)
                .timeout(Duration(milliseconds: timeout));
            break;

          case 'PATCH':
            response = await client
                .patch(
                  uri,
                  headers: headers,
                  body: _encodeBody(body, headers),
                )
                .timeout(Duration(milliseconds: timeout));
            break;

          default:
            return ActionResult.error('Unsupported HTTP method: $method');
        }

        // Parse response
        final responseData = _parseResponse(response);

        return ActionResult.success(data: {
          'status': response.statusCode,
          'statusText': response.reasonPhrase,
          'headers': response.headers,
          'data': responseData,
          'url': url,
          'method': method,
        });
      } finally {
        client.close();
      }
    } catch (e) {
      return ActionResult.error('HTTP request failed: $e');
    }
  }

  /// Parse headers from action
  Map<String, String>? _parseHeaders(dynamic headers) {
    if (headers == null) return null;

    if (headers is Map) {
      return headers.map((key, value) => MapEntry(
            key.toString(),
            value.toString(),
          ));
    }

    return null;
  }

  /// Encode request body
  dynamic _encodeBody(dynamic body, Map<String, String>? headers) {
    if (body == null) return null;

    final contentType = headers?['Content-Type'] ?? headers?['content-type'];

    if (contentType?.contains('application/json') == true) {
      if (body is String) return body;
      return jsonEncode(body);
    }

    if (body is Map || body is List) {
      return jsonEncode(body);
    }

    return body.toString();
  }

  /// Parse response body
  dynamic _parseResponse(http.Response response) {
    final contentType = response.headers['content-type'] ?? '';

    if (contentType.contains('application/json')) {
      try {
        return jsonDecode(response.body);
      } catch (_) {
        return response.body;
      }
    }

    return response.body;
  }
}
