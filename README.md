# EveryNotifyVibe 0.2.0

Rootless SpringBoard tweak intended for iOS 15/16 (Dopamine) that explicitly
requests a vibration for each visible notification bulletin, including rapid
repeated/coalesced notifications.

## Why 0.2.0 exists

The first build hooked `NCNotificationCombinedListViewController`'s
`insertNotificationRequest:` / `modifyNotificationRequest:` methods. Those are
notification-list UI methods. They are useful for a tweak such as Axon that
changes how Notification Center is displayed, but they are not the best place
to detect every incoming alert.

0.2.0 moves the hook earlier in the real delivery path:

`BulletinBoard -> NCBulletinNotificationSource -> NCNotificationDispatcher -> destinations`

It also uses `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` instead of a
UIKit feedback generator, because this tweak needs to work while SpringBoard is
handling notifications with the phone locked/backgrounded.

## Build on GitHub

1. Put all files at the root of your repository. `.github/workflows/build.yml`
   must remain in that exact folder.
2. Commit/push to `main`.
3. Open **Actions -> Build rootless deb -> Run workflow**.
4. Download the `EveryNotifyVibe-rootless-v0.2.0` artifact.
5. Install the `.deb` with Sileo/Zebra and respring.

The package ID is the same as v0.1 (`com.local.everynotifyvibe`) and the version
is higher, so installing 0.2.0 should replace 0.1.0.

## Test

Lock the phone and have somebody send several Snapchat messages/snaps about
2-5 seconds apart. This build should explicitly request a vibration on each
bulletin instead of relying on iOS's native repeated-alert decision.

## Possible double vibration

This version deliberately forces a vibration for every incoming visible
bulletin. The first notification may therefore feel stronger/double if iOS also
plays its normal vibration. That is useful for confirming the hook works. Once
we have confirmed repeated Snapchat alerts vibrate, the next revision can be
changed to supplement only notifications for which the native vibration is
suppressed.

## Compatibility notes

This uses private SpringBoard/BulletinBoard classes and methods. They can vary
between iOS releases. The primary hook is the iOS notification source path, with
three BBServer publication methods as fallback paths. A short 350 ms de-dupe
window prevents one notification travelling through multiple hooked paths from
causing multiple tweak-generated vibrations.
