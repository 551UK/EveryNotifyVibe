# EveryNotifyVibe 0.6.0

A small rootless SpringBoard tweak for iOS 15/16 (Dopamine) that adds a vibration to every visible notification from enabled applications.

## Why it exists

On iOS 16, apps such as Snapchat can vibrate for the first notification while rapid follow-up/grouped notifications are delivered without another vibration. EveryNotifyVibe adds its own vibration for each notification so enabled apps vibrate every time.

## Per-app behaviour

- Master **Enabled** ON + app ON: EveryNotifyVibe forces a vibration for every notification from that app.
- App OFF: EveryNotifyVibe does nothing to that app. iOS handles its notification vibration normally.
- Master **Enabled** OFF: EveryNotifyVibe does nothing to any app.
- Apps are ON by default.
- **Enable All Apps** and **Disable All Apps** are available under Settings -> EveryNotifyVibe -> Applications.

## 0.6 cleanup

0.6 removes the experimental code accumulated in older builds. There is now:

- one notification-delivery hook (`NCBulletinNotificationSource`)
- one preferences domain (`com.local.everynotifyvibe.preferences`)
- one `DisabledApps` array
- one Darwin notification used to reload settings

Removed:

- BBServer fallback hooks
- direct/stale mirror preference plist
- dual preference read paths
- manual stock-vibration recreation
- bulletin ID tracking
- duplicate-event dictionary/debounce
- notification-content heuristics
- unused bulletin properties
- app icon/private UIKit code
- user/system app categorisation

The per-app list and SpringBoard now read/write the same CFPreferences domain, so there is a single source of truth.

## Build with GitHub Actions

1. Upload the complete repository, preserving `.github/workflows/build.yml`.
2. Open **Actions -> Build rootless deb -> Run workflow**.
3. Download the `EveryNotifyVibe-rootless-v0.6.0` artifact.
4. Extract and install the `.deb` with Sileo/Zebra.
5. Respring once after installation/update.

## Test per-app control

1. Make sure Focus / Do Not Disturb is off.
2. Settings -> EveryNotifyVibe -> Enabled = ON.
3. Applications -> Snapchat = OFF.
4. Clear existing Snapchat notifications and lock the phone.
5. The first Snapchat alert should follow normal iOS behaviour; immediate follow-ups may be silent, because EveryNotifyVibe is no longer touching Snapchat.
6. Turn Snapchat ON. New Snapchat notifications should now all receive the tweak-generated vibration.

## Notes

This tweak uses a private iOS SpringBoard notification class, so iOS updates can change the hook. It is intentionally targeted at the iOS 16 behaviour this project was built to address.
