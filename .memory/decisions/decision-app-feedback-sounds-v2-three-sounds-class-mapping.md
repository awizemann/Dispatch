---
title: Decision: app feedback sounds v2 — three sounds, class mapping, shared volume
type: note
permalink: dispatch/decisions/decision-app-feedback-sounds-v2-three-sounds-class-mapping
tags: [sounds, settings, bus, triage]
source_paths: [Dispatch/Services/Notifications, Dispatch/Resources]
source_paths_inferred: false
source_sha: 2e02e96100cf0a74f8c46fde34723901e828595a
created: 2026-07-15
updated: 2026-07-29
reviewed: 2026-07-30
reviewed_by: audit:claude-code (background)
---
Sounds v2 (2026-07-15) established the class-mapped, per-class-gated, shared-volume shape. The Dispatch pivot (2026-07-28) kept the shape and collapsed the classes: there is no triage board and no agent runtime, so the only two events worth a sound are the two bus events.

## Observations
- [decision] TWO bundled mp3s survive (Dispatch/Resources): `buscomm.mp3` = SoundPlayer's `.question` (a question arrived on the bus), `notification.mp3` = `.answer` (an answer landed). The v2 `alert` class and its red-edge triage mapping died with the triage board #sounds
- [convention] SoundPlayer stays a dumb play-now seam (SoundPlaying protocol, @MainActor): callers own timing; the player self-censors only on Defaults keys and missing assets #sounds
- [decision] Settings: a master `notificationSoundsEnabled` gates the per-class keys (`notificationQuestionSoundEnabled`, `notificationAnswerSoundEnabled`) plus ONE shared `notificationSoundVolume` (Double 0…1, default 1.0, read at play time; slider release plays a preview) #settings
- [decision] Sounds fire on real arrivals only — never on redelivery/replay, which is not a new event #bus

## Relations
- relates_to [[Design System and Accessibility Rules]]
