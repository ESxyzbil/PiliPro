#include "smtc_handler.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <SystemMediaTransportControlsInterop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

#include <cstdio>
#include <memory>
#include <string>

using namespace winrt;
using namespace Windows::Media;
using namespace Windows::Storage;
using namespace Windows::Storage::Streams;

class SmtcHandler::Impl {
 public:
  Impl() = default;
  ~Impl() { Cleanup(); }

  void Init(flutter::BinaryMessenger* messenger, HWND hwnd) {
    if (initialized_) return;
    messenger_ = messenger;
    hwnd_ = hwnd;

    try {
      winrt::init_apartment(winrt::apartment_type::single_threaded);

      // 设置 AppUserModelID 让 SMTC 显示正确的应用名
      {
        HRESULT(WINAPI * fnSetAUMID)(PCWSTR) = nullptr;
        HMODULE hShell32 = GetModuleHandleW(L"shell32.dll");
        if (!hShell32) hShell32 = LoadLibraryW(L"shell32.dll");
        if (hShell32) {
          fnSetAUMID = (HRESULT(WINAPI*)(PCWSTR))GetProcAddress(hShell32, "SetCurrentProcessExplicitAppUserModelID");
          if (fnSetAUMID) {
            HRESULT hr = fnSetAUMID(L"ZeroClaw.PiliPlus");
            char buf[128];
            snprintf(buf, sizeof(buf), "[SMTC] SetAUMID hr=0x%08lX\n", hr);
            OutputDebugStringA(buf);
          }
        }
      }

      auto factory =
          winrt::get_activation_factory<SystemMediaTransportControls>();
      auto interop = factory.as<ISystemMediaTransportControlsInterop>();

      interop->GetForWindow(
          hwnd, winrt::guid_of<SystemMediaTransportControls>(),
          winrt::put_abi(smtc_));
      if (!smtc_) {
        OutputDebugStringA("[SMTC] GetForWindow returned null\n");
        return;
      }

      smtc_.IsEnabled(true);
      smtc_.IsPlayEnabled(true);
      smtc_.IsPauseEnabled(true);
      smtc_.IsNextEnabled(true);
      smtc_.IsPreviousEnabled(true);
      smtc_.PlaybackStatus(MediaPlaybackStatus::Stopped);

      // 初始化时设 AppMediaId，但不推空元数据
      {
        auto updater = smtc_.DisplayUpdater();
        updater.Type(MediaPlaybackType::Music);
        updater.AppMediaId(L"PiliPlus");
        // 不推空 title/artist — 等真正播放时再 update
      }

      OutputDebugStringA("[SMTC] Registered successfully\n");

      button_token_ =
          smtc_.ButtonPressed({this, &Impl::OnButtonPressed});

      // Use MethodChannel for cleaner message handling
      method_channel_ = std::make_unique<
          flutter::MethodChannel<flutter::EncodableValue>>(
          messenger_, "windows_smtc",
          &flutter::StandardMethodCodec::GetInstance());

      method_channel_->SetMethodCallHandler(
          [this](
              const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<
                  flutter::MethodResult<flutter::EncodableValue>> result) {
            OutputDebugStringA(
                ("[SMTC] MethodChannel received: " + call.method_name() + "\n")
                    .c_str());
            HandleMethodCall(call, std::move(result));
          });

      OutputDebugStringA("[SMTC] MethodChannel handler set\n");
      initialized_ = true;
    } catch (const winrt::hresult_error& e) {
      char buf[256];
      snprintf(buf, sizeof(buf), "[SMTC] Init failed: 0x%08X\n",
               static_cast<unsigned>(e.code().value));
      OutputDebugStringA(buf);
    } catch (...) {
      OutputDebugStringA("[SMTC] Init failed: unknown error\n");
    }
  }

  void UpdateMetadata(const std::string& title, const std::string& artist,
                      const std::string& thumbnail_path) {
    if (!smtc_) {
      OutputDebugStringA("[SMTC] UpdateMetadata: smtc_ is null\n");
      return;
    }
    try {
      OutputDebugStringA(
          ("[SMTC] Updating metadata: title=" + title + " artist=" + artist +
           " thumb=" + thumbnail_path + "\n")
              .c_str());
      auto updater = smtc_.DisplayUpdater();
      updater.Type(MediaPlaybackType::Music);
      updater.AppMediaId(L"PiliPlus");

      auto music = updater.MusicProperties();
      if (!title.empty()) music.Title(to_hstring(title));
      if (!artist.empty()) music.Artist(to_hstring(artist));

      if (!thumbnail_path.empty()) {
        try {
          if (thumbnail_path.find("://") != std::string::npos) {
            // Has scheme → use as URI
            auto uri = Windows::Foundation::Uri(to_hstring(thumbnail_path));
            auto stream_ref =
                RandomAccessStreamReference::CreateFromUri(uri);
            updater.Thumbnail(stream_ref);
          } else {
            // Local file path
            auto file = StorageFile::GetFileFromPathAsync(
                            to_hstring(thumbnail_path))
                            .get();
            auto stream_ref =
                RandomAccessStreamReference::CreateFromFile(file);
            updater.Thumbnail(stream_ref);
          }
          OutputDebugStringA("[SMTC] Thumbnail set\n");
        } catch (const winrt::hresult_error& e) {
          char buf[256];
          snprintf(buf, sizeof(buf), "[SMTC] Thumbnail failed: 0x%08X\n",
                   static_cast<unsigned>(e.code().value));
          OutputDebugStringA(buf);
        }
      }

      updater.Update();
      OutputDebugStringA("[SMTC] Metadata updated successfully\n");
    } catch (const winrt::hresult_error& e) {
      char buf[256];
      snprintf(buf, sizeof(buf), "[SMTC] UpdateMetadata failed: 0x%08X\n",
               static_cast<unsigned>(e.code().value));
      OutputDebugStringA(buf);
    } catch (...) {
      OutputDebugStringA("[SMTC] UpdateMetadata failed: unknown\n");
    }
  }

  void UpdatePlaybackState(bool is_playing) {
    if (!smtc_) return;
    try {
      smtc_.PlaybackStatus(is_playing ? MediaPlaybackStatus::Playing
                                      : MediaPlaybackStatus::Paused);
      OutputDebugStringA(
          ("[SMTC] Playback state: " + std::string(is_playing ? "playing"
                                                               : "paused") +
           "\n")
              .c_str());
    } catch (...) {
    }
  }

  void Cleanup() {
    if (!initialized_) return;
    try {
      if (smtc_) {
        smtc_.ButtonPressed(button_token_);
        smtc_.IsEnabled(false);
        smtc_ = nullptr;
      }
      method_channel_.reset();
    } catch (...) {
    }
    initialized_ = false;
  }

 private:
  bool initialized_ = false;
  HWND hwnd_ = nullptr;
  flutter::BinaryMessenger* messenger_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  SystemMediaTransportControls smtc_{nullptr};
  winrt::event_token button_token_;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto& method = call.method_name();

    if (method == "updateMetadata") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto get_str = [&](const char* key) -> std::string {
          auto it = args->find(flutter::EncodableValue(key));
          if (it != args->end() &&
              std::holds_alternative<std::string>(it->second)) {
            return std::get<std::string>(it->second);
          }
          return {};
        };
        UpdateMetadata(get_str("title"), get_str("artist"),
                       get_str("thumbnail"));
      }
      result->Success(flutter::EncodableValue(true));
    } else if (method == "updatePlaybackState") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      bool playing = false;
      if (args) {
        auto it = args->find(flutter::EncodableValue("playing"));
        if (it != args->end() &&
            std::holds_alternative<bool>(it->second)) {
          playing = std::get<bool>(it->second);
        }
      }
      UpdatePlaybackState(playing);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "ping") {
      OutputDebugStringA("[SMTC] Ping received\n");
      result->Success(flutter::EncodableValue("pong"));
    } else {
      result->NotImplemented();
    }
  }

  void OnButtonPressed(
      const SystemMediaTransportControls&,
      const SystemMediaTransportControlsButtonPressedEventArgs& args) {
    if (!method_channel_) return;

    std::string command;
    switch (args.Button()) {
      case SystemMediaTransportControlsButton::Play:
        command = "onPlay";
        break;
      case SystemMediaTransportControlsButton::Pause:
        command = "onPause";
        break;
      case SystemMediaTransportControlsButton::Next:
        command = "onNext";
        break;
      case SystemMediaTransportControlsButton::Previous:
        command = "onPrevious";
        break;
      case SystemMediaTransportControlsButton::Stop:
        command = "onPause";
        break;
      default:
        return;
    }

    std::string msg = "[SMTC] ButtonPressed: " + command + "\n";
    OutputDebugStringA(msg.c_str());

    method_channel_->InvokeMethod(command, nullptr, nullptr);
  }
};

SmtcHandler::SmtcHandler() : impl_(new Impl()) {}
SmtcHandler::~SmtcHandler() { delete impl_; }

void SmtcHandler::Init(flutter::BinaryMessenger* messenger, HWND hwnd) {
  impl_->Init(messenger, hwnd);
}

void SmtcHandler::UpdateMetadata(const std::string& title,
                                 const std::string& artist,
                                 const std::string& thumbnail_path) {
  impl_->UpdateMetadata(title, artist, thumbnail_path);
}

void SmtcHandler::UpdatePlaybackState(bool is_playing) {
  impl_->UpdatePlaybackState(is_playing);
}

void SmtcHandler::Cleanup() { impl_->Cleanup(); }
