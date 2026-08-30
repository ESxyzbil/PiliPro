#ifndef RUNNER_LYRICS_OVERLAY_H_
#define RUNNER_LYRICS_OVERLAY_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <Windows.h>

#include <string>

// Desktop lyrics overlay window.
//
// Creates a transparent, click-through, topmost window that displays
// synchronized lyrics text floating above all other windows.
//
// Usage:
//   LyricsOverlay overlay;
//   overlay.Init(messenger, hwnd);        // create the overlay window
//   overlay.SetLyrics("current line", "next line", 0.5);
//   overlay.Show();
//   overlay.Hide();
//   overlay.Cleanup();
class LyricsOverlay {
 public:
  LyricsOverlay();
  ~LyricsOverlay();

  LyricsOverlay(const LyricsOverlay&) = delete;
  LyricsOverlay& operator=(const LyricsOverlay&) = delete;

  // Create the overlay window and register MethodChannel handlers.
  void Init(flutter::BinaryMessenger* messenger, HWND parent_hwnd);

  // Show / hide the overlay window.
  void Show();
  void Hide();

  // Rebuild the overlay window from scratch (fresh surface) and
  // re-render the current lyrics. Used by the "reload" UI button and
  // to recover from display/session/DWM changes.
  void Reload();

  // Update lyrics content.
  // current_line: the active lyric line
  // next_line: the upcoming line (can be empty for single-line mode)
  // progress: 0.0–1.0 indicating how far through current_line we are
  void SetLyrics(const std::string& current_line,
                 const std::string& next_line,
                 double progress);

  // Update display settings.
  void SetPosition(int x, int y);
  void SetFontSize(int size);
  void SetFontFamily(const std::string& family);
  void SetWindowWidth(int width);
  void SetOpacity(int percent);        // 0–100
  void SetLayoutMode(int mode);        // 0=current above next, 2=single line
  void SetTextColor(int r, int g, int b);
  void SetNextTextColor(int r, int g, int b);
  void SetStrokeEnabled(bool enabled);
  void SetStrokeColor(int r, int g, int b);

  // Clean up the overlay window.
  void Cleanup();

 private:
  class Impl;
  Impl* impl_ = nullptr;
};

#endif  // RUNNER_LYRICS_OVERLAY_H_
