#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 81;
constexpr UINT kExitResult = WM_APP + 82;
constexpr UINT_PTR kExitTimeout = 8103;
constexpr UINT kOpen = 8101;
constexpr UINT kExit = 8102;
}

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  restore_window_ = RegisterWindowMessageW(L"chta.RestoreWindow.v1");
  DWORD enabled = 1, size = sizeof(enabled);
  RegGetValueW(HKEY_CURRENT_USER, L"Software\\chta\\Runtime", L"Enabled",
               RRF_RT_REG_DWORD, nullptr, &enabled, &size);
  tray_.enabled = enabled != 0;
  AddTrayIcon();
  runtime_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "app.cht/runtime",
      &flutter::StandardMethodCodec::GetInstance());
  runtime_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "configure") { result->NotImplemented(); return; }
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    bool active = false;
    if (args) {
      auto value = args->find(flutter::EncodableValue("active"));
      if (value != args->end()) {
        if (const auto* b = std::get_if<bool>(&value->second)) active = *b;
      }
      value = args->find(flutter::EncodableValue("enabled"));
      if (value != args->end()) {
        if (const auto* b = std::get_if<bool>(&value->second)) {
          tray_.enabled = *b;
          const DWORD stored = *b ? 1 : 0;
          RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\chta\\Runtime", L"Enabled",
                         REG_DWORD, &stored, sizeof(stored));
        }
      }
    }
    dart_ready_ = true;
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("enabled"), flutter::EncodableValue(tray_.enabled)},
      {flutter::EncodableValue("running"), flutter::EncodableValue(active && tray_.enabled && tray_.icon_available)},
    }));
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  NOTIFYICONDATAW icon = {};
  icon.cbSize = sizeof(icon); icon.hWnd = GetHandle(); icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  if (runtime_channel_) {
    runtime_channel_->SetMethodCallHandler(nullptr);
    runtime_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (restore_window_ && message == restore_window_) { OpenWindow(); return 0; }
  if (taskbar_created_ && message == taskbar_created_) {
    AddTrayIcon();
    if (!tray_.icon_available) OpenWindow();
    return 0;
  }
  if (message == WM_CLOSE) {
    if (tray_.HideOnClose()) ShowWindow(hwnd, SW_HIDE);
    else RequestExit();
    return 0;
  }
  if (message == kExitResult) {
    if (!tray_.exiting || lparam != exit_generation_) return 0;
    KillTimer(hwnd, kExitTimeout);
    if (wparam) DestroyWindow(hwnd);
    else { tray_.ExitRejected(); OpenWindow(); }
    return 0;
  }
  if (message == WM_TIMER && wparam == kExitTimeout) {
    KillTimer(hwnd, kExitTimeout);
    tray_.ExitRejected();
    OpenWindow(); // Never discard unsaved work just because Dart is slow.
    return 0;
  }
  if (message == kTrayMessage) {
    const UINT event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONUP) OpenWindow();
    if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) {
      POINT position; GetCursorPos(&position);
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, kOpen, L"Open chta");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, kExit, L"Exit");
      SetForegroundWindow(hwnd);
      const auto selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
          position.x, position.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      PostMessageW(hwnd, WM_NULL, 0, 0);
      if (selected == kOpen) OpenWindow();
      if (selected == kExit) RequestExit();
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
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

void FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATAW icon = {};
  icon.cbSize = sizeof(icon); icon.hWnd = GetHandle(); icon.uID = 1;
  icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIconW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"chta");
  tray_.icon_available = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  if (tray_.icon_available) {
    icon.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon);
  }
}

void FlutterWindow::OpenWindow() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::RequestExit() {
  if (!tray_.BeginExit()) return;
  const HWND window = GetHandle();
  const LPARAM generation = ++exit_generation_;
  if (!dart_ready_ || !runtime_channel_) { PostMessageW(window, kExitResult, 1, generation); return; }
  SetTimer(window, kExitTimeout, 15000, nullptr);
  runtime_channel_->InvokeMethod("exitRequested", nullptr,
    std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
      [window, generation](const auto* value) {
        const auto* accepted = value ? std::get_if<bool>(value) : nullptr;
        PostMessageW(window, kExitResult, accepted && *accepted ? 1 : 0, generation);
      },
      [window, generation](const auto&, const auto&, const auto*) { PostMessageW(window, kExitResult, 0, generation); },
      [window, generation]() { PostMessageW(window, kExitResult, 0, generation); }));
}
