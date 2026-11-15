# Android PIN session preferences

User request: Profile provides Lock PIN On/Off. Off resumes the latest identity and page without asking PIN after Back/re-entry or process recreation. On requires PIN on the next app entry. Explicit Lock app revokes remembered access and locks immediately. Existing accounts default to On until the user chooses Off.

Use the existing Android Keystore-backed device wrapping key to encrypt a single device resume grant containing the current saved identity secret and last route. Keep the original PIN-protected identity record unchanged. Never save the PIN or plaintext seed/private key. The grant is scoped to the most recently selected identity; choosing another identity or manually locking revokes it. A missing/corrupt grant fails closed to the normal PIN picker; a correct PIN can recover without erasing accounts/history.

Android Back at the root should move the task to the background so a warm session can retain widgets/drafts and current route. Media routes and chat navigation continue their normal back behavior. A cold process resumes from the encrypted grant when Off; the route is restricted to app pages. Network sessions reconnect normally after process death; they cannot remain alive in a killed process.

User chose: On asks only after closing and opening the app, not every background return. Root Back explicitly exits: On locks before leaving; Off keeps the task/session. Home/app switching and app-owned pickers do not lock. App-owned file/media pickers must remain usable and must not accidentally discard staged media.

Approach: native encrypted resume state plus warm task retention. Keeping only an Activity cannot survive process death; storing a PIN or plaintext secret is unsuitable. This is an implementation choice within the requested On/Off behavior, not a new user policy change. Do not silently opt any real account out of PIN protection during testing.
