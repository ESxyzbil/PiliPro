// 把 MP4 转封装/转码为 H.264 + AAC 的 MP4（Windows，Media Foundation 实现）。
//
// 策略：已是 H.264 的视频轨直接复制样本（不重编码、无损、快），已是 AAC 的音频轨
// 同样直接复制；其余编码（HEVC/AV1/FLAC/AC-3…）走解码 + 重编码。硬件编码器可用时
// 由 Media Foundation 自动选用（MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS）。
#ifndef RUNNER_MP4_TRANSCODER_H_
#define RUNNER_MP4_TRANSCODER_H_

#include <functional>
#include <string>

namespace mp4_transcoder {

struct Result {
  bool ok = false;
  std::string error;
  // "copy" = 原样复制， "encode" = 已重编码， "none" = 无此轨
  std::string video_action = "none";
  std::string audio_action = "none";
  std::string video_codec;
  std::string audio_codec;
};

using ProgressCallback = std::function<void(double)>;

/// 把 [input_path] 转成 H.264 + AAC 的 MP4 写到 [output_path]。
/// [on_progress] 会在工作线程上被调用（0~1）。失败时 result.ok 为 false。
Result TranscodeToH264Aac(const std::wstring& input_path,
                          const std::wstring& output_path,
                          const ProgressCallback& on_progress);

}  // namespace mp4_transcoder

#endif  // RUNNER_MP4_TRANSCODER_H_
