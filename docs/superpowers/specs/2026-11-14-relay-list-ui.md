# Relay list and activity

User requested Connect to show one Relays section instead of separate Internet connections/Saved relays, add per-relay added/updated/last-used dates and online status, and use more of the available width.

Keep the connection count/limit as a compact summary in that single section. Each endpoint displays its actual registered/connecting/failed/not-connected state, URL and three concise local timestamps. Do not describe an untested endpoint as offline. Older cached lists lack original dates, so show unknown dates as an em dash rather than inventing them.

Store activity locally alongside existing relay cache. First addition remains stable on reimport; updating metadata or successful registration records an update. Forwarded application route traffic records usage; directory/keepalive traffic alone does not. Coalesce persistence and bound activity entries to the existing relay directory size. Activity is device-local and excluded from exported/gossiped signed catalogs.

Reduce nested horizontal padding on mobile/desktop Connect, use available width, keep pagination for large lists, and retain the existing public relay QR row/copy/save actions.

Implementation is split between relay-network metadata/tests and Connect UI/tests with explicit file ownership after the prior QR/sync handoff. Full integration tests and builds follow all changes in release24.
