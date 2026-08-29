#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>

/*
 * EveryNotifyVibe 0.8.3
 *
 * - one SpringBoard notification hook
 * - one preference domain
 * - per-app enable/disable support
 * - direct DoNotDisturb / Focus-state check
 *
 * Enabled apps get a tweak-generated vibration for every notification while
 * Focus/DND is not suppressing interruptions. Disabled apps and notifications
 * received while Focus/DND is active are left completely untouched.
 */

@interface BBBulletin : NSObject
@property (nonatomic, copy, readonly) NSString *sectionID;
@end

static CFStringRef const ENVPrefsDomain = CFSTR("com.local.everynotifyvibe.preferences");
static CFStringRef const ENVReloadNotification = CFSTR("com.local.everynotifyvibe.preferences/ReloadPrefs");

static BOOL ENVEnabled = YES;
static NSSet<NSString *> *ENVDisabledApps = nil;
static id ENVDNDStateService = nil;

#pragma mark - Preferences

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

        // Cover notification-service extensions belonging to a disabled app.
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

static void ENVInitializeDNDStateService(void) {
    if (ENVDNDStateService) return;

    // Load Apple's private Focus / Do Not Disturb framework at runtime so the
    // tweak does not need to link against a private framework stub.
    dlopen("/System/Library/PrivateFrameworks/DoNotDisturb.framework/DoNotDisturb", RTLD_LAZY);

    Class serviceClass = NSClassFromString(@"DNDStateService");
    SEL serviceSelector = NSSelectorFromString(@"serviceForClientIdentifier:");

    if (serviceClass && [serviceClass respondsToSelector:serviceSelector]) {
        typedef id (*ENVServiceFunction)(id, SEL, id);
        ENVDNDStateService = ((ENVServiceFunction)objc_msgSend)(
            serviceClass,
            serviceSelector,
            @"com.apple.springboard"
        );
    }
}

static BOOL ENVFocusOrDNDIsSuppressingNotifications(void) {
    ENVInitializeDNDStateService();
    if (!ENVDNDStateService) return NO;

    SEL querySelector = NSSelectorFromString(@"queryCurrentStateWithError:");
    if (![ENVDNDStateService respondsToSelector:querySelector]) return NO;

    NSError *__autoreleasing error = nil;
    typedef id (*ENVQueryStateFunction)(id, SEL, NSError *__autoreleasing *);
    id state = ((ENVQueryStateFunction)objc_msgSend)(
        ENVDNDStateService,
        querySelector,
        &error
    );

    if (!state) return NO;

    // `willSuppressInterruptions` is the most direct signal. `isActive` is
    // retained as a fallback/extra guard for Focus states on iOS 16.
    SEL suppressSelector = NSSelectorFromString(@"willSuppressInterruptions");
    if ([state respondsToSelector:suppressSelector]) {
        typedef BOOL (*ENVBoolFunction)(id, SEL);
        if (((ENVBoolFunction)objc_msgSend)(state, suppressSelector)) return YES;
    }

    SEL activeSelector = NSSelectorFromString(@"isActive");
    if ([state respondsToSelector:activeSelector]) {
        typedef BOOL (*ENVBoolFunction)(id, SEL);
        if (((ENVBoolFunction)objc_msgSend)(state, activeSelector)) return YES;
    }

    return NO;
}

#pragma mark - Notification hook

%hook NCBulletinNotificationSource

- (void)observer:(id)observer
     addBulletin:(BBBulletin *)bulletin
         forFeed:(unsigned long long)feed
playLightsAndSirens:(BOOL)playLightsAndSirens
       withReply:(id)reply {

    NSString *sectionID = bulletin.sectionID;

    if (ENVShouldHandleApp(sectionID) &&
        !ENVFocusOrDNDIsSuppressingNotifications()) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }

    // Never interfere with Apple's own notification processing.
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        ENVDisabledApps = [NSSet set];
        ENVLoadPreferences();
        ENVInitializeDNDStateService();

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
