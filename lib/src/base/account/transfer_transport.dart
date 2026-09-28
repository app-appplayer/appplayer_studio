/// Moving a large body to and from the place a transfer ticket points at.
///
/// Kept apart from [HttpSend] because it is a different kind of traffic: the
/// ticket URL is absolute and pre-signed, carries no session of ours, and the
/// payload is raw bytes rather than JSON. Folding the two together would mean
/// every caller that only ever stores small records still has to supply a way
/// to stream megabytes.
///
/// Injected rather than implemented here so this package names no HTTP client
/// and runs in a browser and on a device alike.
library;

import 'dart:typed_data';

/// Raised when the bytes did not make it — the ticket expired, the connection
/// dropped, the signature was refused.
///
/// Distinct from the storage refusals: none of them describe this, and a caller
/// that retries a conflict must not retry a rejected signature the same way.
class TransferFailed implements Exception {
  TransferFailed(this.url, this.status, this.message);

  final String url;

  /// The status the far side gave, or 0 when the request never got an answer.
  final int status;
  final String message;

  @override
  String toString() => 'TransferFailed($status): $message';
}

abstract interface class TransferTransport {
  /// Puts the bytes where the write ticket points.
  ///
  /// [contentType] must be the one the ticket was opened with — the server
  /// binds it into the signature, so a different value is refused. That is
  /// deliberate: without it a leaked ticket takes anything at all.
  Future<void> upload(String url, Uint8List body, String contentType);

  /// Reads the bytes a read ticket points at.
  Future<Uint8List> download(String url);
}
