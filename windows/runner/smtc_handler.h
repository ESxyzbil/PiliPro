#ifndef RUNNER_SMTC_HANDLER_H_
#define RUNNER_SMTC_HANDLER_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <Windows.h>

#include <string>

// Windows System Media Transport Controls (SMTC) handler.
//
// Registers this app as a system media source using the desktop interop
// API (ISystemMediaTransportControlsInterop). This enables:
// - Volume flyout shows playback controls
// - Bluetooth headsets (AVRCP) send play/pause/next/prev
// - Taskbar shows media thumbnail overlay
// - Global media key handling
class SmtcHandler {
 public:
  SmtcHandler();
  ~SmtcHandler();

  SmtcHandler(const SmtcHandler&) = delete;
  SmtcHandler& operator=(const SmtcHandler&) = delete;

  // Initialize SMTC for the given window handle.
  // hwnd: the main app window
  // messenger: from FlutterEngine::messenger()
  void Init(flutter::BinaryMessenger* messenger, HWND hwnd);

  // Update song metadata (title, artist, optional album art path)
  void UpdateMetadata(const std::string& title,
                      const std::string& artist,
                      const std::string& thumbnail_path);

  // Update playback state (playing / paused)
  void UpdatePlaybackState(bool is_playing);

  // Clean up SMTC resources
  void Cleanup();

 private:
  class Impl;
  Impl* impl_ = nullptr;
};

#endif  // RUNNER_SMTC_HANDLER_H_
