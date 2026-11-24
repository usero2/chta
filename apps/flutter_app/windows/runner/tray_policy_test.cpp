// Headless: exercises lifecycle decisions without opening windows/tray icons.
#include "tray_policy.h"
#include <cassert>
#include <string>
#include "desktop_instance.h"
int main() {
  const auto name = L"Local\\chta.QA.Runtime." + std::to_wstring(GetCurrentProcessId());
  DesktopInstance first(name.c_str());
  DesktopInstance second(name.c_str());
  assert(first.valid() && !first.already_running);
  assert(second.valid() && second.already_running);
  TrayPolicy policy;
  assert(!policy.HideOnClose());  // Never hide an unreachable window.
  policy.icon_available = true;
  assert(policy.HideOnClose());
  policy.enabled = false;
  assert(!policy.HideOnClose());
  policy.enabled = true;
  assert(policy.BeginExit());
  assert(!policy.BeginExit());  // One flush handshake, even with rapid clicks.
  policy.ExitRejected();
  assert(policy.HideOnClose());
  assert(policy.BeginExit());
}
