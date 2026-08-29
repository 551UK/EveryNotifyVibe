#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

/*
 * EveryNotifyVibe 0.8.4
 *
 * One notification hook, one preference domain, per-app controls, and live
 * Focus/DND tracking from SpringBoard's own DND state callbacks.
 *
 * Enabled apps: force one vibration for each notification only while no Focus
 * mode / Do Not Disturb state is active.
 * Disabled apps: untouched; stock iOS behaviour only.
 */

@interface BBBulletin : NSObject
@property (nonatomic, copy, readonly) NSString *sectionID;
@end

static CFStringRef const ENVPrefsDomain = CFSTR("com.local.everynotifyvibe.preferences");
static CFStringRef const ENVReloadNotification = CFSTR("com.local.everynotifyvibe.preferences/ReloadPrefs");

static BOOL ENVEnabled = YES;
static NSSet<NSString *> *ENVDisabledApps = nil;

// Updated by SpringBoard's own DND/Focus state callbacks.
static BOOL ENVFocusActive = NO;
static BOOL ENVFocusSuppressing = NO;

#pragma mark - Preferences

static void ENVLoadPreferences(void) {
    CFPreferencesSynchronize(ENVPrefsDomain,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);

    BOOL enabled = YES;
    NSMutableSet<NSString *> *disabled = [NSMutableSet set];

    CFPropertyListRef enabledValue = CFPreferencesCopyValue(
        CFSTR("Enabled"), ENVPrefsDomain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    if (enabledValue && CFGetTypeID(enabledValue) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)enabledValue);
    }
    if (enabledValue) CFRelease(enabledValue);

    CFPropertyListRef disabledValue = CFPreferencesCopyValue(
        CFSTR("DisabledApps"), ENVPrefsDomain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    if (disabledValue && CFGetTypeID(disabledValue) == CFArrayGetTypeID()) {
        for (id value in (__bridge NSArray *)disabledValue) {
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
        if ([sectionID hasPrefix:[bundleID stringByAppendingString:@"."]]) return YES;
    }

    return NO;
}

static BOOL ENVShouldHandleApp(NSString *sectionID) {
    BOOL enabled;
    @synchronized ([NSProcessInfo processInfo]) {
        enabled = ENVEnabled;
    }
    return enabled && !ENVSectionIsDisabled(sectionID);
}

#pragma mark - Focus / Do Not Disturb

static BOOL ENVReadBoolSelector(id object, NSString *selectorName, BOOL *didRead) {
    if (didRead) *didRead = NO;
    if (!object) return NO;

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;

    if (didRead) *didRead = YES;
    typedef BOOL (*ENVBoolMsgSend)(id, SEL);
    return ((ENVBoolMsgSend)objc_msgSend)(object, selector);
}

static void ENVUpdateFocusStateFromObject(id state) {
    if (!state) return;

    BOOL readActive = NO;
    BOOL readSuppressing = NO;

    BOOL active = ENVReadBoolSelector(state, @"isActive", &readActive);
    BOOL suppressing = ENVReadBoolSelector(state, @"willSuppressInterruptions", &readSuppressing);

    // iOS versions/classes can expose only one of these. Keep whichever fields
    // were actually available instead of resetting the other one blindly.
    @synchronized ([NSProcessInfo processInfo]) {
        if (readActive) ENVFocusActive = active;
        if (readSuppressing) ENVFocusSuppressing = suppressing;
    }
}

static BOOL ENVFocusBlocksForcedVibration(void) {
    BOOL active;
    BOOL suppressing;
    @synchronized ([NSProcessInfo processInfo]) {
        active = ENVFocusActive;
        suppressing = ENVFocusSuppressing;
    }

    // User expectation for this tweak: any active Focus/DND mode should stop
    // EveryNotifyVibe's extra vibration. Stock iOS still processes the alert.
    return active || suppressing;
}

/*
 * SpringBoard owns DNDNotificationsService and receives this callback whenever
 * the current DND/Focus state changes. Track Apple's own state object instead
 * of making a separate DNDStateService query.
 */
%hook DNDNotificationsService

- (void)stateService:(id)service didReceiveDoNotDisturbStateUpdate:(id)state {
    ENVUpdateFocusStateFromObject(state);
    %orig;
}

%end

/*
 * Extra live-state safety net. DNDState is queried throughout SpringBoard;
 * whenever Apple asks these getters we mirror the returned current values.
 */
%hook DNDState

- (BOOL)isActive {
    BOOL value = %orig;
    @synchronized ([NSProcessInfo processInfo]) {
        ENVFocusActive = value;
    }
    return value;
}

- (BOOL)willSuppressInterruptions {
    BOOL value = %orig;
    @synchronized ([NSProcessInfo processInfo]) {
        ENVFocusSuppressing = value;
    }
    return value;
}

%end

#pragma mark - Notification hook

%hook NCBulletinNotificationSource

- (void)observer:(id)observer
     addBulletin:(BBBulletin *)bulletin
         forFeed:(unsigned long long)feed
playLightsAndSirens:(BOOL)playLightsAndSirens
       withReply:(id)reply {

    NSString *sectionID = bulletin.sectionID;

    if (ENVShouldHandleApp(sectionID) && !ENVFocusBlocksForcedVibration()) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }

    // Always leave Apple's notification pipeline untouched.
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
