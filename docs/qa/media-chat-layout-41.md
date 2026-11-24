# Media layout: build 0.0.1+41

Images and videos no longer have the message bubble's colored padding around them. Their optional Markdown caption owns a separate colored strip below the media; an empty caption creates no footer. The album uses one caption for the set. A lone video uses the full tile; multiple videos keep their horizontal row. Text, audio and generic file bubbles keep their existing style.

Save/play/cached controls, timestamps and the completed-transfer cleanup remain. Small dark backings keep overlay controls visible over pale media. Streamed large media retains the existing metadata/save fallback and avoids eager preview reads. Peer, local and group rooms select the same visual-media presentation from existing type metadata.

## Verification

- RED/GREEN tests cover removal of media padding/background, caption position and color, absent caption footer, single-video sizing and whitespace-only streamed captions.
- Legacy image/cached video, thumbnail replacement, media opening/pagination/zoom, generic-file metadata and actual peer-room frame checks passed.
- Full regressions caught and resolved a small-tile save-button hitbox overlapping the center tap and an unintended streamed-image preview read. The final tests preserve center tapping and the large-file no-eager-bytes/read-once contract.
- Final Flutter suite: 397 passed, 8 platform/opt-in skips. Static analysis: no issues.
- Independent read-only review found no Critical/Important issues. Minor contrast and whitespace-footer feedback was addressed.
- Android package version 41 was installed and the existing image/video messages inspected: no colored bubble padding surrounds the media, while ordinary text keeps its bubble. Existing timestamps and media controls remain; no real-contact test send was performed.

The reference screenshot and source were inspected privately; no reference image, reference-app source, local path or owner chat content is included here. No protocol, file limit, encryption or transport behavior changed, and no real-contact test message was sent. Final platform builds and owner-device inspection are recorded in local release evidence.
