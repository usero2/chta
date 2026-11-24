#ifndef RUNNER_TRAY_POLICY_H_
#define RUNNER_TRAY_POLICY_H_
struct TrayPolicy {
  bool icon_available = false;
  bool enabled = true;
  bool exiting = false;
  bool HideOnClose() const { return enabled && icon_available && !exiting; }
  bool BeginExit() {
    if (exiting) return false;
    exiting = true;
    return true;
  }
  void ExitRejected() { exiting = false; }
};
#endif
