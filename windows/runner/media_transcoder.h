// 保存到本地时的 H.264+AAC 转码服务（Windows / Media Foundation）。
//
// Flutter 侧通过 MethodChannel "com.example.piliplus/media_transcoder" 调用：
//   transcode({input, output}) -> {ok, videoAction, audioAction}
// 过程中通过同通道回调 "progress"（double 0~1）。
#ifndef RUNNER_MEDIA_TRANSCODER_H_
#define RUNNER_MEDIA_TRANSCODER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <memory>

namespace media_transcoder_channel {
inline constexpr char kChannelName[] =
    "com.example.piliplus/media_transcoder";
/// 后台转码线程完成后投递到窗口消息循环的消息。
inline constexpr UINT kDoneMessage = WM_APP + 0x51;
}  // namespace media_transcoder_channel

class MediaTranscoder {
 public:
  MediaTranscoder();
  ~MediaTranscoder();

  MediaTranscoder(const MediaTranscoder&) = delete;
  MediaTranscoder& operator=(const MediaTranscoder&) = delete;

  void Init(flutter::BinaryMessenger* messenger, HWND hwnd);
  void Cleanup();

  /// 在窗口消息循环里调用；返回 true 表示该消息已处理。
  bool HandleWindowMessage(UINT message);

 private:
  class Impl;
  Impl* impl_ = nullptr;
};

#endif  // RUNNER_MEDIA_TRANSCODER_H_
