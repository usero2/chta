# Android reopen regression — 0.0.1+13

On the MTN NX1 (Android 16, serial ANDROID_DEVICE_SERIAL), leaving an unlocked
activity with Back and reopening it recreated Flutter inside the same process.
The process-wide Rust runtime retained its active identity. Startup then failed
with `Lock the active identity before configuring storage` before `runApp`,
leaving the native splash visible. A cold process launch succeeded.

The Android storage configuration now saves the old account state using the old
vault, clears identity/session keys, and accepts the validated platform vault.
The reopened engine starts at the saved identity/PIN picker. It does not remove
saved identities, contacts, encrypted history, or storage keys.

Flutter draws its first frame before loading storage. Startup errors and a
20-second timeout display a retry screen. A pending timed-out operation is reused
on retry so concurrent startup attempts cannot reset a new session.

Validation:

- Native regression test restores a disposable identity, changes chat state,
  recreates the platform session, verifies it is locked, and unlocks it again to
  verify the profile, contacts and messages. Repeated initialization also passes.
- Widget tests cover pending storage, failure/retry, timeout and disposal.
- APK `0.0.1+13` installed with `adb -s ANDROID_DEVICE_SERIAL install -r` without
  clearing data. Launch: `adb -s ANDROID_DEVICE_SERIAL shell am start -W -n app.cht.cht/.MainActivity`.
- User entered their PIN on the device. Back/reopen retained PID 2855 and returned
  to the identity picker in 169 ms. Three more warm reopen cycles took 216, 173,
  and 164 ms, with no Flutter error in the scoped process log.
- Local proof: `target/android-startup-proof/` and `target/android-proof/`.
  The live mirror was `http://127.0.0.1:59449/`; automatic in-app Browser handoff
  was unavailable because this session exposes no Browser control capability.
