# Profile notification toggle

Replace the Notifications Enable button with the same adaptive switch used by other Profile settings. On asks OS/browser permission only after the user gesture; denied permission leaves the switch off with a concise system-settings hint. Off suppresses future message/file alerts without revoking OS permission or stopping background reception.

Remember the choice per identity on this installation using the existing protected group-blob storage capability. Default to existing granted-permission behavior when no preference exists. Explicit Off must win over delayed initialization or permission results. Never replay alerts suppressed while Off. Storage errors fail closed and are surfaced without breaking chat. Pending preference writes settle before identity lock/switch.

Use shared Flutter code for current Android/Windows/Web clients. Preserve the mandatory Android background-service notice and existing notification privacy/deduplication. No new dependencies, server changes, paid services, owner-message tests, private data publication or Windows GUI actions. Build/audit/install 42 and inspect Profile without changing the owner's preferences.
