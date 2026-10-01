#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "smtc_handler.h"
#include "lyrics_overlay.h"
#include "media_transcoder.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->ForceRedraw();

  // Initialize SMTC — registers this app as a system media source
  smtc_handler_ = std::make_unique<SmtcHandler>();
  smtc_handler_->Init(flutter_controller_->engine()->messenger(),
                      GetHandle());

  // Initialize desktop lyrics overlay (hidden by default)
  lyrics_overlay_ = std::make_unique<LyricsOverlay>();
  lyrics_overlay_->Init(flutter_controller_->engine()->messenger(),
                        GetHandle());

  // 保存到本地：m4s 合并后的 MP4 转码为 H.264 + AAC
  media_transcoder_ = std::make_unique<MediaTranscoder>();
  media_transcoder_->Init(flutter_controller_->engine()->messenger(),
                         GetHandle());

  return true;
}

void FlutterWindow::OnDestroy() {
  if (media_transcoder_) {
    media_transcoder_->Cleanup();
    media_transcoder_.reset();
  }
  lyrics_overlay_.reset();
  smtc_handler_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 转码完成通知先于 Flutter 处理，避免被平台线程的消息处理吞掉
  if (media_transcoder_ && media_transcoder_->HandleWindowMessage(message)) {
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                       lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
