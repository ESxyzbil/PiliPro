#include "media_transcoder.h"

#include <mutex>
#include <string>
#include <thread>

#include "mp4_transcoder.h"

namespace {

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                      static_cast<int>(utf8.size()), out.data(), len);
  return out;
}

std::string GetStringArg(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return std::string();
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return std::string();
}

}  // namespace

class MediaTranscoder::Impl {
 public:
  void Init(flutter::BinaryMessenger* messenger, HWND hwnd) {
    hwnd_ = hwnd;
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, media_transcoder_channel::kChannelName,
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethodCall(call, std::move(result)); });
  }

  void Cleanup() {
    state_->alive = false;
    if (channel_) {
      channel_->SetMethodCallHandler(nullptr);
      channel_.reset();
    }
  }

  bool HandleWindowMessage(UINT message) {
    if (message != media_transcoder_channel::kDoneMessage) {
      return false;
    }
    auto result = std::move(pending_result_);
    mp4_transcoder::Result outcome;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      outcome = state_->result;
    }
    state_->busy = false;
    if (!result) {
      return true;
    }
    if (outcome.ok) {
      flutter::EncodableMap payload;
      payload[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
      payload[flutter::EncodableValue("videoAction")] =
          flutter::EncodableValue(outcome.video_action);
      payload[flutter::EncodableValue("audioAction")] =
          flutter::EncodableValue(outcome.audio_action);
      result->Success(flutter::EncodableValue(payload));
    } else {
      result->Error("transcode_failed", outcome.error);
    }
    return true;
  }

 private:
  struct Shared {
    std::mutex mutex;
    bool busy = false;
    bool alive = true;
    mp4_transcoder::Result result;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() != "transcode") {
      result->NotImplemented();
      return;
    }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "参数格式错误");
      return;
    }
    const std::string input = GetStringArg(*args, "input");
    const std::string output = GetStringArg(*args, "output");
    if (input.empty() || output.empty()) {
      result->Error("bad_args", "缺少输入或输出路径");
      return;
    }
    if (state_->busy) {
      result->Error("busy", "已有转码任务正在进行");
      return;
    }
    state_->busy = true;
    pending_result_ = std::move(result);

    auto state = state_;
    HWND hwnd = hwnd_;
    std::thread([this, state, hwnd, input, output]() {
      auto progress = [this, state](double value) {
        if (!state->alive || !channel_) {
          return;
        }
        channel_->InvokeMethod(
            "progress",
            std::make_unique<flutter::EncodableValue>(value));
      };
      auto outcome = mp4_transcoder::TranscodeToH264Aac(
          Utf8ToWide(input), Utf8ToWide(output), progress);
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->result = outcome;
      }
      if (state->alive && hwnd != nullptr) {
        PostMessageW(hwnd, media_transcoder_channel::kDoneMessage, 0, 0);
      }
    }).detach();
  }

  HWND hwnd_ = nullptr;
  std::shared_ptr<Shared> state_ = std::make_shared<Shared>();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_result_;
};

MediaTranscoder::MediaTranscoder() : impl_(new Impl()) {}

MediaTranscoder::~MediaTranscoder() {
  Cleanup();
  delete impl_;
}

void MediaTranscoder::Init(flutter::BinaryMessenger* messenger, HWND hwnd) {
  impl_->Init(messenger, hwnd);
}

void MediaTranscoder::Cleanup() {
  impl_->Cleanup();
}

bool MediaTranscoder::HandleWindowMessage(UINT message) {
  return impl_->HandleWindowMessage(message);
}
