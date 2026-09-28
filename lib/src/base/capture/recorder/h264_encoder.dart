/// The H.264 encoder the studio's video commands use.
///
/// The app links the LGPL build of FFmpeg (`ffmpeg_kit_flutter_new_full`),
/// which has no x264 — that is GPL, and a GPL component would put every
/// binary that ships it (the closed Pro tier included) under the GPL. H.264
/// therefore comes from:
///
///   * `h264_videotoolbox` — Apple's hardware encoder, on Apple Silicon Macs
///     (the only Macs where FFmpeg exposes VideoToolbox constant quality);
///   * `libopenh264` (BSD) everywhere else. The Linux LGPL build carries no
///     software H.264 encoder at all, so an mp4 encode there fails with
///     FFmpeg's "unknown encoder" error; VP9 (`webm`) exports work.
///
/// Quality stays on the familiar CRF scale (0–51, lower = better, 23 when
/// unset) and is translated to each encoder's own control, so callers and
/// MCP tools keep one knob.
library;

import 'dart:ffi' show Abi;

const String kVideoToolboxH264 = 'h264_videotoolbox';
const String kOpenH264 = 'libopenh264';

/// Studio frames are RGB. Converting them to YUV must use a named matrix and
/// tag the stream with it: left to negotiate, the encode inherits an RGB
/// colour tag that YUV video must not carry, and a VP9 (`webm`) export of
/// such a clip does not decode.
const String kRgbToBt709Filter = 'scale=out_color_matrix=bt709:out_range=tv';
const String kBt709Tags =
    '-colorspace bt709 -color_primaries bt709 -color_trc bt709';

/// Quality used when a caller gives none — x264's default CRF.
const int kDefaultCrf = 23;

/// The H.264 encoder for [abi] (default: the running one).
String h264EncoderFor([Abi? abi]) =>
    (abi ?? Abi.current()) == Abi.macosArm64 ? kVideoToolboxH264 : kOpenH264;

/// `-c:v … -pix_fmt … <quality>` for an encode at [crf] (0–51). [encoder]
/// defaults to [h264EncoderFor] the running platform; any other encoder a
/// caller names gets FFmpeg's own `-crf`.
String h264VideoArgs({
  int? crf,
  String? encoder,
  String pixelFormat = 'yuv420p',
}) {
  final enc = encoder ?? h264EncoderFor();
  final c = (crf ?? kDefaultCrf).clamp(0, 51);
  final quality = switch (enc) {
    // VideoToolbox constant quality is 1–100, higher = better; map the CRF
    // scale linearly (CRF 0 → 100, CRF 51 → 1). `allow_sw` keeps the encode
    // working where the hardware session is unavailable (e.g. a VM).
    kVideoToolboxH264 => '-allow_sw 1 -q:v ${(100 - c * 99 / 51).round()}',
    // openh264 has no CRF; its rate control honours the quantiser range
    // (with rate control off it ignores it), so clamp that to the value.
    kOpenH264 => '-rc_mode quality -qmin $c -qmax $c',
    _ => '-crf $c',
  };
  return '-c:v $enc -pix_fmt $pixelFormat $quality';
}
