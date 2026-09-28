/// One-time FFmpegKit setup the studio needs before its first FFmpeg call.
library;

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/signal.dart';

Future<void>? _prepared;

/// FFmpegKit handles SIGINT and SIGTERM itself once it runs, so a studio
/// that has encoded once no longer ends on either — a script or a gate that
/// stops the studio by signal left it running. The studio leaves both to
/// the process. Runs once; a failure only means the signals stay with
/// FFmpegKit.
Future<void> prepareFfmpegKit() =>
    _prepared ??= () async {
      try {
        await FFmpegKitConfig.ignoreSignal(Signal.sigTerm);
        await FFmpegKitConfig.ignoreSignal(Signal.sigInt);
      } catch (_) {
        /* best-effort — encoding still works */
      }
    }();
