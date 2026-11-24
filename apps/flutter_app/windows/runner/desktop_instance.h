#ifndef RUNNER_DESKTOP_INSTANCE_H_
#define RUNNER_DESKTOP_INSTANCE_H_
#include <windows.h>
class DesktopInstance {
 public:
  explicit DesktopInstance(const wchar_t* name = L"Local\\chta.Desktop.Runtime.v1") {
    handle_ = CreateMutexW(nullptr, FALSE, name);
    already_running = handle_ && GetLastError() == ERROR_ALREADY_EXISTS;
  }
  ~DesktopInstance() { if (handle_) CloseHandle(handle_); }
  bool valid() const { return handle_ != nullptr; }
  bool already_running = false;
  DesktopInstance(const DesktopInstance&) = delete;
  DesktopInstance& operator=(const DesktopInstance&) = delete;
 private:
  HANDLE handle_ = nullptr;
};
#endif
