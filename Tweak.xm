#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

/*
 * EveryNotifyVibe v0.4.0
 * iOS 15/16 rootless (Dopamine)
 *
 * Forces a vibration for each visible notification bulletin, including rapid
 * repeated/coalesced notifications that iOS may otherwise deliver silently.
 *
 * v0.4 adds per-application filtering. All applications are enabled by
 * default. The Settings bundle stores only bundle identifiers the user has
 * disabled, so newly installed applications automatically start enabled.
 */

@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *bulletinID;
@property (nonatomic, copy) NSString *recordID;
@property (nonatomic, copy) NSString *publisherBulletinID;
@property (nonatomic, copy) NSString *threadID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *message;
@end

static NSMutableDictionary<NSString *, NSNumber *> *ENVRecentEvents;
static const NSTimeInterval ENVDuplicateWindow = 0.35;

static CFStringRef const ENVPreferencesDomain = CFSTR("com.local.everynotifyvibe.preferences");
static CFStringRef const ENVPreferencesChangedNotification = CFSTR("com.local.everynotifyvibe.preferences/ReloadPrefs");

static BOOL ENVEnabled = YES;
static NSSet<NSString *> *ENVDisabledApplications;

static void ENVLoadPreferences(void) {
    CFPreferencesAppSynchronize(ENVPreferencesDomain);

    CFPropertyListRef enabledValue = CFPreferencesCopyAppValue(CFSTR("Enabled"), ENVPreferencesDomain);
    if (enabledValue && CFGetTypeID(enabledValue) == CFBooleanGetTypeID()) {
        ENVEnabled = CFBooleanGetValue((CFBooleanRef)enabledValue);
    } else {
        ENVEnabled = YES;
    }
    if (enabledValue) CFRelease(enabledValue);

    CFPropertyListRef disabledValue = CFPreferencesCopyAppValue(CFSTR("DisabledApps"), ENVPreferencesDomain);
    if (disabledValue && CFGetTypeID(disabledValue) == CFArrayGetTypeID()) {
        NSArray *array = (__bridge NSArray *)disabledValue;
        NSMutableSet<NSString *> *validIDs = [NSMutableSet set];
        for (id value in array) {
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                [validIDs addObject:value];
            }
        }
        ENVDisabledApplications = [validIDs copy];
    } else {
        // No saved list means every app is enabled by default.
        ENVDisabledApplications = [NSSet set];
    }
    if (disabledValue) CFRelease(disabledValue);
}

static void ENVPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
    ENVLoadPreferences();
}

static NSString *ENVString(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSString *ENVSectionIDFromBulletin(id bulletin) {
    if (!bulletin) return nil;

    NSString *sectionID = nil;
    if ([bulletin respondsToSelector:@selector(sectionID)]) {
        sectionID = ENVString([bulletin sectionID]);
    }

    if (sectionID.length == 0 && [bulletin respondsToSelector:NSSelectorFromString(@"section")]) {
        @try {
            sectionID = ENVString([bulletin valueForKey:@"section"]);
        } @catch (__unused NSException *e) {}
    }

    return sectionID;
}

static NSString *ENVIdentifierFromBulletin(id bulletin) {
    if (!bulletin) return nil;

    NSArray<NSString *> *keys = @[@"bulletinID", @"recordID", @"publisherBulletinID"];
    for (NSString *key in keys) {
        @try {
            id value = [bulletin valueForKey:key];
            NSString *string = ENVString(value);
            if (string.length > 0) return string;
        } @catch (__unused NSException *e) {}
    }

    return nil;
}

static BOOL ENVLooksLikeUserNotification(id bulletin) {
    if (!bulletin) return NO;
    if (ENVSectionIDFromBulletin(bulletin).length == 0) return NO;

    NSArray<NSString *> *contentKeys = @[@"title", @"subtitle", @"message"];
    for (NSString *key in contentKeys) {
        @try {
            NSString *value = ENVString([bulletin valueForKey:key]);
            if (value.length > 0) return YES;
        } @catch (__unused NSException *e) {}
    }

    return ENVIdentifierFromBulletin(bulletin).length > 0;
}

static NSString *ENVEventKey(id bulletin, NSString *fallbackSectionID) {
    NSString *sectionID = ENVSectionIDFromBulletin(bulletin);
    if (sectionID.length == 0) sectionID = fallbackSectionID;
    if (sectionID.length == 0) return nil;

    NSString *identifier = ENVIdentifierFromBulletin(bulletin);
    if (identifier.length == 0) {
        identifier = [NSString stringWithFormat:@"ptr-%p", bulletin];
    }

    return [NSString stringWithFormat:@"%@|%@", sectionID, identifier];
}

static BOOL ENVApplicationIsEnabled(NSString *sectionID) {
    if (sectionID.length == 0) return YES;
    return ![ENVDisabledApplications containsObject:sectionID];
}

static void ENVForceVibrationForBulletin(id bulletin, NSString *fallbackSectionID) {
    if (!ENVEnabled) return;
    if (!bulletin) return;

    NSString *sectionID = ENVSectionIDFromBulletin(bulletin);
    if (sectionID.length == 0) sectionID = fallbackSectionID;
    if (sectionID.length == 0) return;

    // Per-app switch: disabled apps fall back to normal iOS behaviour.
    if (!ENVApplicationIsEnabled(sectionID)) return;

    if (!ENVLooksLikeUserNotification(bulletin)) return;

    NSString *key = ENVEventKey(bulletin, sectionID);
    if (!key) return;

    @synchronized (ENVRecentEvents) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSNumber *previous = ENVRecentEvents[key];

        if (previous && (now - previous.doubleValue) < ENVDuplicateWindow) {
            return;
        }

        ENVRecentEvents[key] = @(now);

        if (ENVRecentEvents.count > 512) {
            [ENVRecentEvents removeAllObjects];
            ENVRecentEvents[key] = @(now);
        }
    }

    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

%hook NCBulletinNotificationSource

- (void)observer:(id)observer
     addBulletin:(id)bulletin
         forFeed:(unsigned long long)feed
playLightsAndSirens:(BOOL)playLightsAndSirens
       withReply:(id)reply {

    ENVForceVibrationForBulletin(bulletin, nil);
    %orig;
}

%end

%hook BBServer

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    ENVForceVibrationForBulletin(bulletin, nil);
    %orig;
}

- (void)publishBulletin:(id)bulletin
           destinations:(unsigned long long)destinations
     alwaysToLockScreen:(BOOL)alwaysToLockScreen {
    ENVForceVibrationForBulletin(bulletin, nil);
    %orig;
}

- (void)_publishBulletinRequest:(id)request
                   forSectionID:(NSString *)sectionID
                forDestinations:(unsigned long long)destinations
             alwaysToLockScreen:(BOOL)alwaysToLockScreen {
    ENVForceVibrationForBulletin(request, sectionID);
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        ENVRecentEvents = [NSMutableDictionary dictionary];
        ENVDisabledApplications = [NSSet set];
        ENVLoadPreferences();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            ENVPreferencesChanged,
            ENVPreferencesChangedNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
}
