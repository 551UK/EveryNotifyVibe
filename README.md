# EveryNotifyVibe 0.4.3

## Build setup

The preference bundle now pins the build SDK to `iPhoneOS16.5.sdk` instead of `latest`. The GitHub workflow already downloads the patched Theos SDK repository, and the patched iOS 16.5 SDK contains the private framework stubs needed to link `Preferences.framework`. This fixes the GitHub Actions error `ld: framework 'Preferences' not found`. The deployment target remains iOS 15.0.


Rootless SpringBoard tweak for iOS 15/16 (Dopamine) that explicitly requests a vibration for each enabled app notification bulletin, including rapid repeated/coalesced notifications.

## Why it exists

With normal iOS 16 notification behaviour, apps such as Snapchat can vibrate for the first notification and then deliver notifications that arrive straight afterwards without another vibration. EveryNotifyVibe supplements that behaviour by explicitly triggering a vibration for each incoming notification.

## New in 0.4.3

- **Per-app controls** in Settings.
- **Every app is enabled by default**.
- **Enable All Apps** button.
- **Disable All Apps** button.
- New apps automatically default to enabled because the tweak stores only the apps you turn off.
- Per-app changes apply immediately without a respring.
- The existing master **Enabled** switch remains available.

## Settings

Open:

**Settings -> EveryNotifyVibe**

- **Enabled**: master switch for the whole tweak.
- **Applications**: choose which individual apps receive EveryNotifyVibe's forced vibration.
- Inside **Applications**, use **Enable All Apps** or **Disable All Apps** for bulk changes.

Turning an individual app off does **not** disable the app's normal iOS notifications or native vibration. It only stops EveryNotifyVibe from adding its own forced vibration for that app.

## Build on GitHub

1. Upload the complete repository and preserve `.github/workflows/build.yml` plus the `EveryNotifyVibePrefs` folder.
2. Commit/push to `main`.
3. Open **Actions -> Build rootless deb -> Run workflow**.
4. Download the `EveryNotifyVibe-rootless-v0.4.3` artifact.
5. Install the `.deb` with Sileo/Zebra and respring once after upgrading.

## How the per-app setting works

The preference domain is:

`com.local.everynotifyvibe.preferences`

`DisabledApps` contains an array of bundle identifiers that have been switched off. If an app is not in that array, it is enabled. This means a fresh install and newly installed apps default to ON.

The tweak reads the notification bulletin's `sectionID` (normally the app bundle identifier) and skips the forced vibration when that identifier is in `DisabledApps`.

## Notification hook

EveryNotifyVibe hooks SpringBoard's BulletinBoard/UserNotifications delivery path rather than only the Notification Center list UI. A short 350 ms duplicate guard prevents one bulletin travelling through multiple hooked methods from producing multiple tweak-generated vibrations.

## Note about the first vibration

EveryNotifyVibe adds its own system vibration. If iOS also produces a native vibration for the first notification, that first alert can feel stronger/double. Follow-up notifications that iOS normally suppresses are the main use case for the tweak.


## Stock-vibration restoration

An earlier build exposed a problem on some iOS 16 setups: turning an application off in
the per-app list could also leave its first normal notification without a
haptic. The primary `NCBulletinNotificationSource` hook now behaves as follows:

- Enabled app: EveryNotifyVibe vibrates for every notification, including when
  `playLightsAndSirens` is false for a rapid/grouped follow-up.
- Disabled app: EveryNotifyVibe only supplies the stock-style vibration when
  iOS sets `playLightsAndSirens` to true. Follow-ups marked false stay silent.
- Master switch off: the same stock-style restoration is used for all apps.

This means an app that is switched off should once again behave like normal
iOS 16: the initial alert can vibrate, while immediate grouped/repeated alerts
may not.


## v0.4.3 per-app fix

0.4.3 fixes a case where turning an app off could still leave EveryNotifyVibe
active for that app. Notification service extensions can publish under a section
identifier derived from, but not exactly equal to, the main app bundle ID. The
filter now treats `com.example.app.*` notification sections as belonging to
`com.example.app`.

The disabled-app list is also mirrored to a direct preferences plist so
SpringBoard can reload per-app changes reliably across processes.
