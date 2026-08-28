#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

/*
 * EveryNotifyVibe v0.4.3
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
static NSString * const ENVDisabledAppsFile = @"/var/mobile/Library/Preferences/com.local.everynotifyvibe.disabledapps.plist";

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

    /*
     * Per-app state is mirrored to a small plist file by the Settings bundle.
     * Reading it directly avoids any cfprefsd cross-process caching/sandbox
     * weirdness between Settings and SpringBoard. CFPreferences remains the
     * fallback for backwards compatibility.
     */
    NSArray *disabledArray = [NSArray arrayWithContentsOfFile:ENVDisabledAppsFile];

    CFPropertyListRef disabledValue = NULL;
    if (![disabledArray isKindOfClass:[NSArray class]]) {
        disabledValue = CFPreferencesCopyAppValue(CFSTR("DisabledApps"), ENVPreferencesDomain);
        if (disabledValue && CFGetTypeID(disabledValue) == CFArrayGetTypeID()) {
            disabledArray = (__bridge NSArray *)disabledValue;
        }
    }

    if ([disabledArray isKindOfClass:[NSArray class]]) {
        NSMutableSet<NSString *> *validIDs = [NSMutableSet set];
        for (id value in disabledArray) {
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

static BOOL ENVSectionMatchesDisabledApplication(NSString *sectionID) {
    if (sectionID.length == 0) return NO;

    for (NSString *disabledID in ENVDisabledApplications) {
        if (disabledID.length == 0) continue;

        // Normal notification section identifier.
        if ([sectionID isEqualToString:disabledID]) return YES;

        /*
         * Notification-service extensions commonly use an identifier derived
         * from the containing app, e.g. com.example.app.NotificationService.
         * Treat those as belonging to the disabled parent app as well.
         */
        NSString *extensionPrefix = [disabledID stringByAppendingString:@"."];
        if ([sectionID hasPrefix:extensionPrefix]) return YES;
    }

    return NO;
}

static BOOL ENVApplicationIsEnabled(NSString *sectionID) {
    // Unknown/no section IDs should not bypass an explicit per-app filter.
    if (sectionID.length == 0) return NO;
    return !ENVSectionMatchesDisabledApplication(sectionID);
}

static void ENVPlayVibrationForBulletin(id bulletin, NSString *fallbackSectionID, NSString *modeTag) {
    if (!bulletin) return;

    NSString *sectionID = ENVSectionIDFromBulletin(bulletin);
    if (sectionID.length == 0) sectionID = fallbackSectionID;
    if (sectionID.length == 0) return;

    if (!ENVLooksLikeUserNotification(bulletin)) return;

    NSString *key = ENVEventKey(bulletin, sectionID);
    if (!key) return;
    if (modeTag.length > 0) {
        key = [key stringByAppendingFormat:@"|%@", modeTag];
    }

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

static BOOL ENVShouldForceEveryNotification(NSString *sectionID) {
    return ENVEnabled && ENVApplicationIsEnabled(sectionID);
}

%hook NCBulletinNotificationSource

- (void)observer:(id)observer
     addBulletin:(id)bulletin
         forFeed:(unsigned long long)feed
playLightsAndSirens:(BOOL)playLightsAndSirens
       withReply:(id)reply {

    NSString *sectionID = ENVSectionIDFromBulletin(bulletin);

    /*
     * Enabled app: force a vibration on every bulletin, even when iOS sets
     * playLightsAndSirens to NO for a rapid/grouped follow-up.
     *
     * Disabled app (or master switch off): preserve stock-style behaviour.
     * v0.4.1 revealed that merely skipping our forced vibration could leave
     * the normal haptic absent on this hook path. To make "Off" behave like
     * iOS again, we explicitly reproduce the normal alert vibration only when
     * iOS itself marks this bulletin playLightsAndSirens == YES. Rapid/grouped
     * follow-ups that iOS marks NO remain silent, matching the iOS 16 pattern.
     */
    if (ENVShouldForceEveryNotification(sectionID)) {
        ENVPlayVibrationForBulletin(bulletin, nil, @"force");
    } else if (playLightsAndSirens) {
        ENVPlayVibrationForBulletin(bulletin, nil, @"stock");
    }

    %orig;
}

%end

%hook BBServer

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    NSString *sectionID = ENVSectionIDFromBulletin(bulletin);
    if (ENVShouldForceEveryNotification(sectionID)) {
        ENVPlayVibrationForBulletin(bulletin, nil, @"force");
    }
    %orig;
}

- (void)publishBulletin:(id)bulletin
           destinations:(unsigned long long)destinations
     alwaysToLockScreen:(BOOL)alwaysToLockScreen {
    NSString *sectionID = ENVSectionIDFromBulletin(bulletin);
    if (ENVShouldForceEveryNotification(sectionID)) {
        ENVPlayVibrationForBulletin(bulletin, nil, @"force");
    }
    %orig;
}

- (void)_publishBulletinRequest:(id)request
                   forSectionID:(NSString *)sectionID
                forDestinations:(unsigned long long)destinations
             alwaysToLockScreen:(BOOL)alwaysToLockScreen {
    if (ENVShouldForceEveryNotification(sectionID)) {
        ENVPlayVibrationForBulletin(request, sectionID, @"force");
    }
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
