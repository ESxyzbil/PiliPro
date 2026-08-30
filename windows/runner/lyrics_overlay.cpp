#include "lyrics_overlay.h"

#include <dwmapi.h>
#include <gdiplus.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#pragma comment(lib, "gdiplus.lib")

using namespace Gdiplus;

// ============================================================
// Constants
// ============================================================
static constexpr int kDefaultWidth = 1200;
static constexpr int kDefaultHeight = 140;
static constexpr int kFontSize = 28;
static constexpr int kSubFontSize = 20;
static constexpr int kMargin = 40;
static constexpr int kLineGap = 8;
static constexpr UINT_PTR kKeepAliveTimerId = 1001;
static constexpr int kKeepAliveIntervalMs = 1000;  // 1s keepalive: recover from display/DWM changes
// Layout modes
static constexpr int kLayoutCurrentAbove = 0;
static constexpr int kLayoutSingleLine = 2;
// Text alignment
static constexpr int kAlignLeft = 0;
static constexpr int kAlignCenter = 1;
static constexpr int kAlignRight = 2;
// Font style
static constexpr int kFontRegular = 0;
static constexpr int kFontBold = 1;
static constexpr int kFontItalic = 2;
static constexpr int kFontBoldItalic = 3;

// ============================================================
// Helpers
// ============================================================
static GdiplusStartupInput g_gdiplus_startup;
static ULONG_PTR g_gdiplus_token = 0;

static void EnsureGdiplus() {
  static bool init = false;
  if (!init) {
    GdiplusStartup(&g_gdiplus_token, &g_gdiplus_startup, nullptr);
    init = true;
  }
}

static void CleanupGdiplus() {
  if (g_gdiplus_token) {
    GdiplusShutdown(g_gdiplus_token);
    g_gdiplus_token = 0;
  }
}

// ============================================================
// Implementation
// ============================================================
class LyricsOverlay::Impl {
 public:
  Impl() = default;
  ~Impl() {
    Cleanup();
    CleanupGdiplus();
  }

  // ---- Font enumeration ----

  /// Callback for EnumFontFamiliesEx
  std::vector<std::string> EnumerateFonts() {
    std::vector<std::string> fonts;
    InstalledFontCollection font_collection;
    int count = font_collection.GetFamilyCount();
    if (count > 0) {
      std::vector<FontFamily> families(count);
      int found = 0;
      if (font_collection.GetFamilies(count, families.data(), &found) == Ok) {
        for (int i = 0; i < found; i++) {
          WCHAR name[LF_FACESIZE] = {};
          families[i].GetFamilyName(name);
          if (name[0]) {
            int len = WideCharToMultiByte(CP_UTF8, 0, name, -1, nullptr, 0,
                                          nullptr, nullptr);
            if (len > 0) {
              std::string font_name(static_cast<size_t>(len) - 1, '\0');
              WideCharToMultiByte(CP_UTF8, 0, name, -1, &font_name[0], len,
                                  nullptr, nullptr);
              fonts.push_back(font_name);
            }
          }
        }
      }
    }
    std::sort(fonts.begin(), fonts.end());
    fonts.erase(std::unique(fonts.begin(), fonts.end()), fonts.end());
    return fonts;
  }

  // ---- Public API ----

  void Init(flutter::BinaryMessenger* messenger, HWND parent_hwnd) {
    if (initialized_) return;
    EnsureGdiplus();
    parent_hwnd_ = parent_hwnd;
    messenger_ = messenger;

    RegisterWindowClass();
    EnsureChannel();
    EnsureWindow();

    initialized_ = true;
  }

  void Show() {
    EnsureWindow();
    if (!hwnd_) return;
    visible_ = true;
    OutputDebugStringA("[Lyrics] Show called\n");
    ShowWindow(hwnd_, SW_SHOWNA);
    PushFrame();
  }

  void Hide() {
    visible_ = false;
    OutputDebugStringA("[Lyrics] Hide called\n");
    if (hwnd_ && IsWindow(hwnd_)) ShowWindow(hwnd_, SW_HIDE);
  }

  /// Manual reload: rebuild the overlay window from scratch (fresh
  /// surface) and re-render the current lyrics. Exposed to the Dart
  /// side as the "reload" MethodChannel method.
  void Reload() {
    if (hwnd_ && IsWindow(hwnd_)) {
      KillTimer(hwnd_, kKeepAliveTimerId);
      DestroyWindow(hwnd_);  // triggers WM_DESTROY -> HandleDestroy
    }
    hwnd_ = nullptr;
    EnsureWindow();
    if (hwnd_ && visible_) PushFrame();
  }

  void SetLyrics(const std::string& current_line,
                 const std::string& next_line, double progress) {
    char buf[512];
    snprintf(buf, sizeof(buf),
             "[Lyrics] SetLyrics empty=%d len=%zu\n",
             current_line.empty(), current_line.size());
    OutputDebugStringA(buf);
    lyrics_current_ = current_line;
    lyrics_next_ = next_line;
    progress_ = std::clamp(progress, 0.0, 1.0);
    EnsureWindow();
    Invalidate();
  }

  void SetPosition(int x, int y) {
    pos_x_ = x;
    pos_y_ = y;
    EnsureWindow();
    if (!hwnd_) return;
    SetWindowPos(hwnd_, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }

  void SetFontSize(int size) {
    font_size_ = std::max(12, std::min(72, size));
    sub_font_size_ = std::max(10, font_size_ - 8);
    EnsureWindow();
    Invalidate();
  }

  void SetOpacity(int percent) {
    opacity_ = std::clamp(percent, 0, 100);
    EnsureWindow();
    Invalidate();
  }

  void SetFontFamily(const std::string& family) {
    if (!family.empty()) font_family_name_ = family;
    EnsureWindow();
    Invalidate();
  }

  void SetWindowWidth(int width) {
    if (width < 200) width = 200;
    if (width > 3840) width = 3840;
    window_width_ = width;
    EnsureWindow();
    if (hwnd_) {
      RECT r;
      GetWindowRect(hwnd_, &r);
      int cy = r.bottom - r.top;
      SetWindowPos(hwnd_, nullptr, r.left, r.top, width, cy,
                   SWP_NOZORDER | SWP_NOACTIVATE);
    }
    Invalidate();
  }

  void SetLayoutMode(int mode) {
    layout_mode_ = mode;
    EnsureWindow();
    Invalidate();
  }

  void SetTextColor(int r, int g, int b) {
    text_color_r_ = std::clamp(r, 0, 255);
    text_color_g_ = std::clamp(g, 0, 255);
    text_color_b_ = std::clamp(b, 0, 255);
    EnsureWindow();
    Invalidate();
  }

  void SetNextTextColor(int r, int g, int b) {
    next_text_color_r_ = std::clamp(r, 0, 255);
    next_text_color_g_ = std::clamp(g, 0, 255);
    next_text_color_b_ = std::clamp(b, 0, 255);
    EnsureWindow();
    Invalidate();
  }

  void SetStrokeEnabled(bool enabled) {
    stroke_enabled_ = enabled;
    EnsureWindow();
    Invalidate();
  }

  void SetStrokeColor(int r, int g, int b) {
    stroke_color_r_ = std::clamp(r, 0, 255);
    stroke_color_g_ = std::clamp(g, 0, 255);
    stroke_color_b_ = std::clamp(b, 0, 255);
    EnsureWindow();
    Invalidate();
  }

  void SetDraggable(bool draggable) {
    EnsureWindow();
    if (!hwnd_) return;
    LONG style = GetWindowLong(hwnd_, GWL_EXSTYLE);
    if (draggable) {
      style &= ~WS_EX_TRANSPARENT;
    } else {
      style |= WS_EX_TRANSPARENT;
    }
    SetWindowLong(hwnd_, GWL_EXSTYLE, style);
    draggable_ = draggable;
  }

  void Cleanup() {
    if (hwnd_ && IsWindow(hwnd_)) {
      KillTimer(hwnd_, kKeepAliveTimerId);
      DestroyWindow(hwnd_);
    }
    hwnd_ = nullptr;
    method_channel_.reset();
    initialized_ = false;
  }

 private:
  // ---- Window lifecycle ----

  /// Register the overlay window class (idempotent; a second
  /// RegisterClass with the same name simply fails with
  /// ERROR_CLASS_ALREADY_EXISTS, which is fine).
  void RegisterWindowClass() {
    const wchar_t kClassName[] = L"PiliPlusLyricsOverlay";
    WNDCLASS wc = {};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kClassName;
    RegisterClass(&wc);
  }

  /// Register the MethodChannel handler (idempotent).
  void EnsureChannel() {
    if (method_channel_ || !messenger_) return;
    method_channel_ = std::make_unique<
        flutter::MethodChannel<flutter::EncodableValue>>(
        messenger_, "desktop_lyrics",
        &flutter::StandardMethodCodec::GetInstance());
    method_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<
                   flutter::MethodResult<flutter::EncodableValue>> result) {
          HandleMethodCall(call, std::move(result));
        });
  }

  /// (Re)create the overlay window if it was destroyed for any reason
  /// (DWM restart, display/session change, etc.). The overlay is
  /// self-healing: any later show / setLyrics / settings call brings a
  /// dead window back, instead of silently failing forever.
  void EnsureWindow() {
    if (hwnd_ && IsWindow(hwnd_)) return;
    CreateOverlayWindow();
    if (hwnd_ && visible_) {
      ShowWindow(hwnd_, SW_SHOWNA);
      PushFrame();
    }
  }

  void CreateOverlayWindow() {
    if (hwnd_ && IsWindow(hwnd_)) return;

    // Get primary monitor dimensions for default positioning
    RECT work_area = {0};
    SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
    int screen_w = work_area.right - work_area.left;

    int win_w = window_width_;
    int win_h = window_height_;
    // Use stored position if available, else center horizontally + above taskbar
    int win_x = pos_x_ >= 0 ? pos_x_ : (screen_w - win_w) / 2;
    int win_y = pos_y_ >= 0 ? pos_y_ : work_area.bottom - win_h - 60;

    // Create layered window
    hwnd_ = CreateWindowEx(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        L"PiliPlusLyricsOverlay", L"PiliPlus Lyrics",
        WS_POPUP,  // no caption, no border
        win_x, win_y, win_w, win_h,
        nullptr,  // no parent
        nullptr, GetModuleHandle(nullptr), this);

    if (!hwnd_) return;

    // Store this pointer in window user data
    SetWindowLongPtr(hwnd_, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(this));

    // 1s keepalive: periodically re-push the frame so the layered
    // surface recovers from display/session/DWM events. Repaints are
    // otherwise driven on demand by Invalidate().
    SetTimer(hwnd_, kKeepAliveTimerId, kKeepAliveIntervalMs, nullptr);
  }

  /// Called when the overlay window is destroyed (WM_DESTROY).
  /// Keeps all state (lyrics, settings, visibility) so the window can
  /// be transparently recreated by EnsureWindow().
  void HandleDestroy() {
    if (hwnd_) {
      KillTimer(hwnd_, kKeepAliveTimerId);
      hwnd_ = nullptr;
    }
  }

  /// Display / power / setting changed: refresh the layered surface.
  void OnSystemEvent() {
    EnsureWindow();
    if (hwnd_ && visible_) PushFrame();
  }

  // ---- Fields ----
  bool initialized_ = false;
  bool visible_ = false;
  HWND hwnd_ = nullptr;
  HWND parent_hwnd_ = nullptr;
  flutter::BinaryMessenger* messenger_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;

  std::string lyrics_current_;
  std::string lyrics_next_;
  double progress_ = 0.0;

  int font_size_ = kFontSize;
  int sub_font_size_ = kSubFontSize;
  int opacity_ = 85;
  int window_width_ = kDefaultWidth;
  int window_height_ = kDefaultHeight;
  int pos_x_ = -1;
  int pos_y_ = -1;
  int layout_mode_ = kLayoutCurrentAbove;
  int text_align_ = kAlignCenter;
  int font_style_ = kFontRegular;
  bool stroke_enabled_ = true;
  bool draggable_ = false;
  int text_color_r_ = 255, text_color_g_ = 255, text_color_b_ = 255;
  int next_text_color_r_ = 255, next_text_color_g_ = 255, next_text_color_b_ = 255;
  int stroke_color_r_ = 0, stroke_color_g_ = 0, stroke_color_b_ = 0;
  std::string font_family_name_ = "Microsoft YaHei";

  // ---- Painting ----

  /// Push a frame to the layered window via UpdateLayeredWindow.
  void PushFrame() {
    if (!hwnd_ || !visible_) {
      OutputDebugStringA("[Lyrics] PushFrame: skip (hwnd=");
      char buf[64];
      snprintf(buf, sizeof(buf), "%d visible=%d)\n", !!hwnd_, visible_);
      OutputDebugStringA(buf);
      return;
    }

    RECT rect;
    GetWindowRect(hwnd_, &rect);
    int w = rect.right - rect.left;
    int h = rect.bottom - rect.top;
    if (w <= 0 || h <= 0) return;

    // ---- Dynamic height: measure text first to see how much space we need ----
    int gdi_style = FontStyleRegular;
    switch (font_style_) {
      case kFontBold:       gdi_style = FontStyleBold; break;
      case kFontItalic:     gdi_style = FontStyleItalic; break;
      case kFontBoldItalic: gdi_style = FontStyleBoldItalic; break;
      default:              gdi_style = FontStyleRegular;
    }

    HDC measure_dc = GetDC(nullptr);
    float text_area_w = static_cast<float>(w - kMargin * 2);
    float cur_h = 0.0f, next_h = 0.0f;
    if (measure_dc) {
      // Create a temporary GDI+ Graphics for measurement
      Graphics g_measure(measure_dc);
      g_measure.SetSmoothingMode(SmoothingModeAntiAlias);
      g_measure.SetTextRenderingHint(TextRenderingHintAntiAlias);

      auto measure = [&](const std::string& text, int fs, float& out_h) {
        if (text.empty()) { out_h = 0; return; }
        std::wstring wt = Utf8ToWide(text);
        std::wstring ffw = Utf8ToWide(font_family_name_);
        FontFamily* ff_ptr;
        FontFamily ff(ffw.c_str());
        static FontFamily ff_fallback(L"Arial");
        if (ff.GetLastStatus() == Ok) {
          ff_ptr = &ff;
        } else {
          ff_ptr = &ff_fallback;
        }
        Font f(ff_ptr, static_cast<REAL>(fs), gdi_style, UnitPixel);
        RectF lr(0, 0, text_area_w, 2000);
        RectF b;
        g_measure.MeasureString(wt.c_str(), -1, &f, lr, &b);
        out_h = b.Height;
      };

      float cur_h_val = 0, next_h_val = 0;
      measure(lyrics_current_, font_size_, cur_h_val);
      measure(lyrics_next_, sub_font_size_, next_h_val);
      cur_h = cur_h_val;
      next_h = next_h_val;

      float needed_h;
      if (layout_mode_ == kLayoutSingleLine || lyrics_next_.empty()) {
        needed_h = std::max(cur_h + 20.0f, (float)kDefaultHeight);
      } else {
        needed_h = cur_h + next_h + kLineGap + 32.0f;  // generous padding
      }
      // Also cap at reasonable maximum
      needed_h = std::max(needed_h, (float)kDefaultHeight);
      needed_h = std::min(needed_h, 600.0f);

      int new_h = std::max(static_cast<int>(needed_h + 0.5f), kDefaultHeight);
      if (new_h != h) {
        h = new_h;
        window_height_ = h;
        // Resize window
        SetWindowPos(hwnd_, nullptr, rect.left, rect.top, w, h,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        // Re-get rect after resize
        GetWindowRect(hwnd_, &rect);
      }
      ReleaseDC(nullptr, measure_dc);
    }
    // ---- End dynamic height ----

    HDC screen_dc = GetDC(nullptr);

    // Create 32-bit DIB with alpha channel
    BITMAPV5HEADER bi = {};
    bi.bV5Size = sizeof(BITMAPV5HEADER);
    bi.bV5Width = w;
    bi.bV5Height = -h;  // top-down
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_RGB;
    bi.bV5AlphaMask = 0xFF000000;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;

    void* bits = nullptr;
    HBITMAP dib = CreateDIBSection(
        screen_dc, reinterpret_cast<BITMAPINFO*>(&bi),
        DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dib) {
      ReleaseDC(nullptr, screen_dc);
      return;
    }

    HDC mem_dc = CreateCompatibleDC(screen_dc);
    HGDIOBJ old_bmp = SelectObject(mem_dc, dib);

    // Initialize to fully transparent
    memset(bits, 0, static_cast<size_t>(w) * h * 4);

    // Draw with GDI+
    {
      Graphics graphics(mem_dc);
      graphics.SetSmoothingMode(SmoothingModeAntiAlias);
      graphics.SetTextRenderingHint(TextRenderingHintAntiAlias);

      if (!lyrics_current_.empty()) {
        DrawLyricLine(graphics, lyrics_current_, true, w, h, cur_h, next_h);
      }
      if (!lyrics_next_.empty()) {
        DrawLyricLine(graphics, lyrics_next_, false, w, h, cur_h, next_h);
      }
    }

    // UpdateLayeredWindow with ULW_ALPHA requires pre-multiplied alpha.
    // GDI+ outputs straight alpha, so we must convert each pixel.
    uint32_t* pixels = static_cast<uint32_t*>(bits);
    int total = w * h;
    for (int i = 0; i < total; i++) {
      uint32_t p = pixels[i];
      uint32_t a = (p >> 24) & 0xFF;
      if (a == 0) {
        // Fully transparent: set to 0 (no color bleed)
        pixels[i] = 0;
      } else if (a < 255) {
        // Premultiply: R = R * a / 255, G = G * a / 255, B = B * a / 255
        uint32_t r = ((p >> 16) & 0xFF) * a / 255;
        uint32_t g = ((p >> 8) & 0xFF) * a / 255;
        uint32_t b = (p & 0xFF) * a / 255;
        pixels[i] = (a << 24) | (r << 16) | (g << 8) | b;
      }
      // a == 255: already correct (straight alpha = premultiplied when a=255)
    }

    // Push to layered window
    BLENDFUNCTION blend = {};
    blend.BlendOp = AC_SRC_OVER;
    blend.SourceConstantAlpha = static_cast<BYTE>(255 * opacity_ / 100);
    blend.AlphaFormat = AC_SRC_ALPHA;

    POINT pt_zero = {0, 0};
    POINT pt_pos = {rect.left, rect.top};
    SIZE size = {w, h};
    BOOL result = UpdateLayeredWindow(hwnd_, screen_dc, &pt_pos, &size, mem_dc, &pt_zero,
                        RGB(0, 0, 0), &blend, ULW_ALPHA);
    if (!result) {
      char buf[128];
      snprintf(buf, sizeof(buf), "[Lyrics] UpdateLayeredWindow failed: %lu\n",
               GetLastError());
      OutputDebugStringA(buf);
    }

    SelectObject(mem_dc, old_bmp);
    DeleteDC(mem_dc);
    DeleteObject(dib);
    ReleaseDC(nullptr, screen_dc);
  }

  void Invalidate() {
    if (hwnd_ && visible_) {
      // Directly push frame instead of waiting for WM_PAINT
      PushFrame();
    }
  }

  /// Convert UTF-8 string to UTF-16 (for GDI+ which uses wchar_t)
  static std::wstring Utf8ToWide(const std::string& utf8) {
    if (utf8.empty()) return {};
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (len <= 0) return {};
    std::wstring wstr(static_cast<size_t>(len) - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wstr[0], len);
    return wstr;
  }

  void DrawLyricLine(Graphics& g, const std::string& text, bool is_current,
                     int win_w, int win_h, float cur_h, float next_h) {
    std::wstring wtext = Utf8ToWide(text);
    if (wtext.empty()) return;

    int fs = is_current ? font_size_ : sub_font_size_;
    float alpha = is_current ? 1.0f : 0.5f;

    // Map font style
    int gdi_style = FontStyleRegular;
    switch (font_style_) {
      case kFontBold:       gdi_style = FontStyleBold; break;
      case kFontItalic:     gdi_style = FontStyleItalic; break;
      case kFontBoldItalic: gdi_style = FontStyleBoldItalic; break;
      default:              gdi_style = FontStyleRegular;
    }

    // Use configured font family
    std::wstring font_family_w = Utf8ToWide(font_family_name_);
    FontFamily msyh(font_family_w.c_str());
    FontFamily* font_family = &msyh;
    if (msyh.GetLastStatus() != Ok) {
      static FontFamily fallback(L"Arial");
      font_family = &fallback;
    }
    Font font(font_family, static_cast<REAL>(fs), gdi_style, UnitPixel);

    // Measure text with wrapping
    float text_area_w = static_cast<REAL>(win_w - kMargin * 2);
    RectF layout_rect(0, 0, text_area_w, 2000);
    RectF bounds;
    g.MeasureString(wtext.c_str(), -1, &font, layout_rect, &bounds);

    float text_w = bounds.Width;
    float text_h = bounds.Height;

    // Horizontal alignment
    float x;
    switch (text_align_) {
      case kAlignLeft:   x = kMargin; break;
      case kAlignRight:  x = win_w - text_w - kMargin; break;
      default:           x = (win_w - text_w) / 2.0f;  // Center
    }

    // Block-center the two lines vertically
    float y;
    if (layout_mode_ == kLayoutSingleLine || lyrics_next_.empty()) {
      // Single line: center vertically
      y = (win_h - text_h) / 2.0f;
    } else if (is_current) {
      // Current line at top of block
      float total_h = cur_h + next_h + kLineGap;
      y = (win_h - total_h) / 2.0f;
    } else {
      // Next line below current
      float total_h = cur_h + next_h + kLineGap;
      y = (win_h - total_h) / 2.0f + cur_h + kLineGap;
    }

    // Colors
    Color outline_color, text_color;
    if (is_current) {
      text_color = Color(static_cast<BYTE>(alpha * 255),
                         static_cast<BYTE>(text_color_r_),
                         static_cast<BYTE>(text_color_g_),
                         static_cast<BYTE>(text_color_b_));
      outline_color = Color(static_cast<BYTE>(alpha * 200),
                            static_cast<BYTE>(stroke_color_r_),
                            static_cast<BYTE>(stroke_color_g_),
                            static_cast<BYTE>(stroke_color_b_));
    } else {
      text_color = Color(static_cast<BYTE>(alpha * 255),
                         static_cast<BYTE>(next_text_color_r_),
                         static_cast<BYTE>(next_text_color_g_),
                         static_cast<BYTE>(next_text_color_b_));
      outline_color = Color(static_cast<BYTE>(alpha * 200),
                            static_cast<BYTE>(stroke_color_r_),
                            static_cast<BYTE>(stroke_color_g_),
                            static_cast<BYTE>(stroke_color_b_));
    }

    // Outline
    StringFormat format;
    format.SetAlignment(StringAlignmentNear);
    format.SetLineAlignment(StringAlignmentNear);

    // Draw outline (offset by 1px in 4 directions + center)
    // Outline with wrapping
    RectF text_rect(x, y, text_area_w, 2000);
    if (stroke_enabled_) {
      for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
          if (dx == 0 && dy == 0) continue;
          RectF outline_rect(x + dx, y + dy, text_area_w, 2000);
          SolidBrush outline_brush(outline_color);
          g.DrawString(wtext.c_str(), -1, &font, outline_rect, &format,
                       &outline_brush);
        }
      }
    }

    // Main text with wrapping
    SolidBrush text_brush(text_color);
    g.DrawString(wtext.c_str(), -1, &font, text_rect, &format, &text_brush);
  }

  // ---- Window Procedure ----

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                                      LPARAM lparam) {
    auto* impl = reinterpret_cast<Impl*>(
        GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (!impl) return DefWindowProc(hwnd, msg, wparam, lparam);

    switch (msg) {
      case WM_PAINT: {
        // For WS_EX_LAYERED windows, rendering is driven by PushFrame()
        // via Invalidate() or timer. We still validate to avoid message storms.
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        EndPaint(hwnd, &ps);
        return 0;
      }
      case WM_ERASEBKGND:
        return 1;  // No background erasing needed
      case WM_TIMER:
        if (wparam == kKeepAliveTimerId) {
          // Periodically re-push in case of display changes
          if (impl->visible_ && impl->hwnd_) {
            impl->PushFrame();
          }
        }
        return 0;
      case WM_DISPLAYCHANGE:
      case WM_SETTINGCHANGE:
        // Display configuration / system settings changed: refresh the
        // layered surface (and recreate the window if it was lost).
        impl->OnSystemEvent();
        return 0;
      case WM_POWERBROADCAST:
        // Screen sleep/wake cycles are a common cause of layered
        // windows vanishing; refresh when the system resumes.
        if (wparam == PBT_APMRESUMEAUTOMATIC ||
            wparam == PBT_APMRESUMESUSPEND) {
          impl->OnSystemEvent();
          return 0;
        }
        break;
      case WM_DESTROY:
        impl->HandleDestroy();
        return 0;
    }
    return DefWindowProc(hwnd, msg, wparam, lparam);
  }

  // ---- MethodChannel ----

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto& method = call.method_name();

    if (method == "show") {
    OutputDebugStringA("[Lyrics] HandleMethodCall: show\n");
      Show();
      result->Success(flutter::EncodableValue(true));
    } else if (method == "hide") {
      Hide();
      result->Success(flutter::EncodableValue(true));
    } else if (method == "reload") {
      OutputDebugStringA("[Lyrics] HandleMethodCall: reload\n");
      Reload();
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setLyrics") {
      OutputDebugStringA("[Lyrics] HandleMethodCall: setLyrics\n");
      const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto get_str = [&](const char* key) -> std::string {
          auto it = args->find(flutter::EncodableValue(key));
          if (it != args->end() &&
              std::holds_alternative<std::string>(it->second)) {
            return std::get<std::string>(it->second);
          }
          return {};
        };
        double progress = 0.0;
        auto it = args->find(flutter::EncodableValue("progress"));
        if (it != args->end()) {
          if (std::holds_alternative<double>(it->second)) {
            progress = std::get<double>(it->second);
          } else if (std::holds_alternative<int>(it->second)) {
            progress = static_cast<double>(std::get<int>(it->second));
          }
        }
        SetLyrics(get_str("currentLine"), get_str("nextLine"), progress);
      }
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setPosition") {
      const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments());
      int x = 0, y = 0;
      if (args) {
        auto get_int = [&](const char* key, int def) -> int {
          auto it = args->find(flutter::EncodableValue(key));
          if (it != args->end()) {
            if (std::holds_alternative<int>(it->second))
              return std::get<int>(it->second);
          }
          return def;
        };
        x = get_int("x", 0);
        y = get_int("y", 0);
      }
      SetPosition(x, y);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setFontSize") {
      const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments());
      int size = kFontSize;
      if (args) {
        auto it = args->find(flutter::EncodableValue("size"));
        if (it != args->end() &&
            std::holds_alternative<int>(it->second)) {
          size = std::get<int>(it->second);
        }
      }
      SetFontSize(size);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setOpacity") {
      const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments());
      int pct = 85;
      if (args) {
        auto it = args->find(flutter::EncodableValue("percent"));
        if (it != args->end() &&
            std::holds_alternative<int>(it->second)) {
          pct = std::get<int>(it->second);
        }
      }
      SetOpacity(pct);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setFontFamily") {
      const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments());
      std::string family = "Microsoft YaHei";
      if (args) {
        auto it = args->find(flutter::EncodableValue("family"));
        if (it != args->end() &&
            std::holds_alternative<std::string>(it->second)) {
          family = std::get<std::string>(it->second);
        }
      }
      SetFontFamily(family);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setWindowWidth") {
      const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments());
      int w = kDefaultWidth;
      if (args) {
        auto it = args->find(flutter::EncodableValue("width"));
        if (it != args->end() &&
            std::holds_alternative<int>(it->second)) {
          w = std::get<int>(it->second);
        }
      }
      SetWindowWidth(w);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setLayoutMode") {
      const auto* args =
          std::get_if<flutter::EncodableMap>(call.arguments());
      int mode = 0;
      if (args) {
        auto it = args->find(flutter::EncodableValue("mode"));
        if (it != args->end() &&
            std::holds_alternative<int>(it->second)) {
          mode = std::get<int>(it->second);
        }
      }
      SetLayoutMode(mode);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setTextColor") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      int r = 255, g = 255, b = 255;
      if (args) {
        auto gi = [&](const char* k, int d) {
          auto it = args->find(flutter::EncodableValue(k));
          if (it != args->end() && std::holds_alternative<int>(it->second))
            return std::get<int>(it->second);
          return d;
        };
        r = gi("r", 255); g = gi("g", 255); b = gi("b", 255);
      }
      SetTextColor(r, g, b);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setNextTextColor") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      int r = 255, g = 255, b = 255;
      if (args) {
        auto gi = [&](const char* k, int d) {
          auto it = args->find(flutter::EncodableValue(k));
          if (it != args->end() && std::holds_alternative<int>(it->second))
            return std::get<int>(it->second);
          return d;
        };
        r = gi("r", 255); g = gi("g", 255); b = gi("b", 255);
      }
      SetNextTextColor(r, g, b);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setStrokeEnabled") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      bool en = true;
      if (args) {
        auto it = args->find(flutter::EncodableValue("enabled"));
        if (it != args->end() && std::holds_alternative<bool>(it->second))
          en = std::get<bool>(it->second);
      }
      SetStrokeEnabled(en);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setStrokeColor") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      int r = 0, g = 0, b = 0;
      if (args) {
        auto gi = [&](const char* k, int d) {
          auto it = args->find(flutter::EncodableValue(k));
          if (it != args->end() && std::holds_alternative<int>(it->second))
            return std::get<int>(it->second);
          return d;
        };
        r = gi("r", 0); g = gi("g", 0); b = gi("b", 0);
      }
      SetStrokeColor(r, g, b);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setDraggable") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      bool en = false;
      if (args) {
        auto it = args->find(flutter::EncodableValue("enabled"));
        if (it != args->end() && std::holds_alternative<bool>(it->second))
          en = std::get<bool>(it->second);
      }
      SetDraggable(en);
      result->Success(flutter::EncodableValue(true));
    } else if (method == "enumerateFonts") {
      auto fonts = EnumerateFonts();
      flutter::EncodableList font_list;
      for (const auto& f : fonts) {
        font_list.push_back(flutter::EncodableValue(f));
      }
      result->Success(flutter::EncodableValue(font_list));
    } else if (method == "setFontStyle") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      int s = 0;
      if (args) {
        auto it = args->find(flutter::EncodableValue("style"));
        if (it != args->end() && std::holds_alternative<int>(it->second))
          s = std::get<int>(it->second);
      }
      font_style_ = std::clamp(s, 0, 3);
      if (visible_) PushFrame();
      result->Success(flutter::EncodableValue(true));
    } else if (method == "setTextAlign") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      int a = 1;
      if (args) {
        auto it = args->find(flutter::EncodableValue("align"));
        if (it != args->end() && std::holds_alternative<int>(it->second))
          a = std::get<int>(it->second);
      }
      text_align_ = std::clamp(a, 0, 2);
      if (visible_) PushFrame();
      result->Success(flutter::EncodableValue(true));
    } else {
      result->NotImplemented();
    }
  }
};

// ============================================================
// Public API
// ============================================================
LyricsOverlay::LyricsOverlay() : impl_(new Impl()) {}
LyricsOverlay::~LyricsOverlay() { delete impl_; }

void LyricsOverlay::Init(flutter::BinaryMessenger* messenger,
                          HWND parent_hwnd) {
  impl_->Init(messenger, parent_hwnd);
}
void LyricsOverlay::Show() { impl_->Show(); }
void LyricsOverlay::Hide() { impl_->Hide(); }
void LyricsOverlay::Reload() { impl_->Reload(); }
void LyricsOverlay::SetLyrics(const std::string& current_line,
                               const std::string& next_line,
                               double progress) {
  impl_->SetLyrics(current_line, next_line, progress);
}
void LyricsOverlay::SetPosition(int x, int y) { impl_->SetPosition(x, y); }
void LyricsOverlay::SetFontSize(int size) { impl_->SetFontSize(size); }
void LyricsOverlay::SetFontFamily(const std::string& family) { impl_->SetFontFamily(family); }
void LyricsOverlay::SetWindowWidth(int width) { impl_->SetWindowWidth(width); }
void LyricsOverlay::SetOpacity(int percent) { impl_->SetOpacity(percent); }
void LyricsOverlay::SetLayoutMode(int mode) { impl_->SetLayoutMode(mode); }
void LyricsOverlay::SetTextColor(int r, int g, int b) { impl_->SetTextColor(r, g, b); }
void LyricsOverlay::SetNextTextColor(int r, int g, int b) { impl_->SetNextTextColor(r, g, b); }
void LyricsOverlay::SetStrokeEnabled(bool enabled) { impl_->SetStrokeEnabled(enabled); }
void LyricsOverlay::SetStrokeColor(int r, int g, int b) { impl_->SetStrokeColor(r, g, b); }
void LyricsOverlay::Cleanup() { impl_->Cleanup(); }
