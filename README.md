# EveryNotifyVibe 0.8.3

Rootless SpringBoard tweak for iOS 15/16 (Dopamine) that forces every incoming notification from enabled apps to vibrate, including repeated/grouped notifications that iOS 16 may normally deliver silently.

## Applications page

- Search bar pinned at the top
- Search by app name or bundle identifier
- Third-party **Applications** and **System Apps** are separated
- App icons are shown next to their switches when available
- Section footers show enabled counts
- Top-right **Actions** menu provides:
  - Enable All Apps
  - Disable All Apps
  - Enable Applications
  - Disable Applications
  - Enable System Apps
  - Disable System Apps
- Individual app switches still apply immediately

All apps are enabled by default. Disabling an app means EveryNotifyVibe does nothing to that app and stock iOS notification vibration behaviour is left untouched.

## Why it exists

With normal iOS 16 behaviour, apps such as Snapchat can vibrate for the first notification while rapid follow-up notifications may not vibrate again. For enabled apps, EveryNotifyVibe forces every incoming notification to vibrate.


## Developer

Made by **551**.

GitHub: https://github.com/551UK

## Build on GitHub

1. Replace the files in your repository with this version.
2. Run **Build rootless deb** in GitHub Actions.
3. Download `EveryNotifyVibe-rootless-v0.8.3`.
4. Install the `.deb` and respring.

## Focus / Do Not Disturb

EveryNotifyVibe respects iOS alert suppression. If Focus or Do Not Disturb suppresses a notification, the tweak will not force a vibration for it.

## Focus / Do Not Disturb fix in 0.8.3

0.8.3 no longer relies on the notification callback's `playLightsAndSirens` value to detect Focus/DND. It queries Apple's DoNotDisturb state service directly and skips EveryNotifyVibe's forced vibration whenever Focus/DND is active or suppressing interruptions. Stock iOS notification processing is always allowed to continue normally.
