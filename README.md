# EveryNotifyVibe

A minimal SpringBoard tweak for **rootless iOS 15/16 jailbreaks** (including Dopamine) that adds a Taptic Engine haptic whenever SpringBoard receives a new notification or a coalesced/grouped notification update.

The main reason for the second hook is repeated notifications from apps such as Snapchat: iOS can update/coalesce an existing notification rather than treating every arrival like a completely separate visible alert.

## Target

- iOS 15.x / 16.x
- Rootless jailbreaks such as Dopamine
- arm64 / arm64e
- SpringBoard only
- No injection into Snapchat or other App Store apps

## What it hooks

`NCNotificationCombinedListViewController`:

- `insertNotificationRequest:forCoalescedNotification:`
- `modifyNotificationRequest:forCoalescedNotification:`

Both methods call Apple's original implementation first. The tweak then fires a medium `UIImpactFeedbackGenerator` haptic.

A 120 ms per-request debounce prevents the tweak itself from creating duplicate pulses when SpringBoard sends near-identical callbacks for the same request.

## Important behaviour

This tweak **adds** a haptic. It does not suppress Apple's normal notification vibration.

That means a notification which already receives a native vibration may sometimes feel stronger or like two closely spaced pulses. Repeated/coalesced notifications which iOS normally leaves silent are the notifications this project is primarily intended to fix.

If you only want the extra vibration for repeated/coalesced notifications, remove this line from the `insertNotificationRequest:` hook in `Tweak.xm`:

```objc
ENVFireHapticForRequest(request);
```

Then rebuild. The `modifyNotificationRequest:` hook will remain active.

## Build automatically with GitHub Actions

1. Create a new GitHub repository.
2. Upload **all files and folders from this project**, including the hidden `.github` folder.
3. Commit them to `main`.
4. Open the **Actions** tab in GitHub.
5. Select **Build rootless deb**.
6. Click **Run workflow** (or simply push another commit; pushes to `main` also trigger a build).
7. When the job finishes, open the completed workflow run.
8. Under **Artifacts**, download `EveryNotifyVibe-rootless`.
9. Extract it. The resulting `.deb` is the package to install on the jailbroken iPhone.

The workflow uses Theos and builds with `THEOS_PACKAGE_SCHEME = rootless` from the Makefile.

## Build locally with Theos

If Theos is already installed:

```sh
make clean package FINALPACKAGE=1
```

The package will appear in:

```text
packages/
```

## Install

Install the generated `.deb` using a rootless-compatible package manager/file installer, then respring.

If installing from a terminal on-device, the usual form is:

```sh
sudo dpkg -i /path/to/com.local.everynotifyvibe_0.1.0_iphoneos-arm64.deb
sbreload
```

The exact generated filename may include the version/build information.

## Uninstall / recovery

Because this hooks a private SpringBoard class, test it cautiously.

If SpringBoard becomes unstable:

1. Enter the jailbreak's tweak-disabled/safe mode.
2. Uninstall **EveryNotifyVibe** in Sileo/Zebra or with `dpkg`.
3. Respring/reboot userspace as appropriate.

## Files

```text
EveryNotifyVibe/
├── .github/
│   └── workflows/
│       └── build.yml
├── .gitignore
├── EveryNotifyVibe.plist
├── LICENSE
├── Makefile
├── README.md
├── Tweak.xm
└── control
```

## Package ID

The current package ID is:

```text
com.local.everynotifyvibe
```

You can change this in `control` before publishing the tweak publicly.

## Notes

- `Settings > Sounds & Haptics > System Haptics` should be enabled.
- This is intentionally a tiny tweak with no preference bundle or dependencies beyond the normal tweak-injection environment.
- It is designed around notification hooks used by iOS 15/16-era SpringBoard. Private API can differ between iOS releases.
