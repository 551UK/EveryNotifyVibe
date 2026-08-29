#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>

/*
 * EveryNotifyVibe 0.8.2
 *
 * Intentionally small:
 * - one SpringBoard notification hook
 * - one preference domain
 * - one master switch
 * - one set containing disabled application bundle identifiers
 *
 * Enabled applications get one tweak-generated vibration for every bulletin.
 * Disabled applications are left completely untouched and fall through to
 * Apple's normal notification behaviour via %orig.
 */

@interface BBBulletin : NSObject
@property (nonatomic, copy, readonly) NSString *sectionID;
@end

static CFStringRef const ENVPrefsDomain = CFSTR("com.local.everynotifyvibe.preferences");
static CFStringRef const ENVReloadNotification = CFSTR("com.local.everynotifyvibe.preferences/ReloadPrefs");

static BOOL ENVEnabled = YES;
static NSSet<NSString *> *ENVDisabledApps = nil;

static void ENVLoadPreferences(void) {
    CFPreferencesSynchronize(
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    BOOL enabled = YES;
    NSMutableSet<NSString *> *disabled = [NSMutableSet set];

    CFPropertyListRef enabledValue = CFPreferencesCopyValue(
        CFSTR("Enabled"),
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    if (enabledValue && CFGetTypeID(enabledValue) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)enabledValue);
    }
    if (enabledValue) CFRelease(enabledValue);

    CFPropertyListRef disabledValue = CFPreferencesCopyValue(
        CFSTR("DisabledApps"),
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    if (disabledValue && CFGetTypeID(disabledValue) == CFArrayGetTypeID()) {
        NSArray *array = (__bridge NSArray *)disabledValue;
        for (id value in array) {
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                [disabled addObject:value];
            }
        }
    }
    if (disabledValue) CFRelease(disabledValue);

    @synchronized ([NSProcessInfo processInfo]) {
        ENVEnabled = enabled;
        ENVDisabledApps = [disabled copy];
    }
}

static void ENVPreferencesChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    ENVLoadPreferences();
}

static BOOL ENVSectionIsDisabled(NSString *sectionID) {
    if (sectionID.length == 0) return YES;

    NSSet<NSString *> *disabledApps;
    @synchronized ([NSProcessInfo processInfo]) {
        disabledApps = ENVDisabledApps;
    }

    for (NSString *bundleID in disabledApps) {
        if ([sectionID isEqualToString:bundleID]) return YES;

        // Also cover an extension whose bundle identifier is derived from the
        // containing application, e.g. com.example.app.NotificationService.
        if ([sectionID hasPrefix:[bundleID stringByAppendingString:@"."]]) return YES;
    }

    return NO;
}

static BOOL ENVShouldVibrate(NSString *sectionID) {
    BOOL enabled;
    @synchronized ([NSProcessInfo processInfo]) {
        enabled = ENVEnabled;
    }

    return enabled && !ENVSectionIsDisabled(sectionID);
}

%hook NCBulletinNotificationSource

- (void)observer:(id)observer
     addBulletin:(BBBulletin *)bulletin
         forFeed:(unsigned long long)feed
playLightsAndSirens:(BOOL)playLightsAndSirens
       withReply:(id)reply {

    NSString *sectionID = bulletin.sectionID;

    // Respect iOS alert suppression (Focus / Do Not Disturb / quiet delivery).
    // We only add our vibration when iOS says this bulletin is allowed to alert.
    if (ENVShouldVibrate(sectionID) && playLightsAndSirens) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }

    // Always let iOS continue its normal notification processing.
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        ENVDisabledApps = [NSSet set];
        ENVLoadPreferences();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            ENVPreferencesChanged,
            ENVReloadNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
}
