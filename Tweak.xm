#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

/*
 * EveryNotifyVibe v0.2.0
 * iOS 15/16 rootless (Dopamine)
 *
 * Why this version is different:
 * v0.1 hooked Notification Center list-controller insert/modify methods. Those
 * describe list/UI changes and are not guaranteed to run for every incoming
 * alert, especially repeated/coalesced notifications.
 *
 * v0.2 hooks the BulletinBoard -> UserNotifications notification delivery path
 * in SpringBoard, before the alert is presented. This is the point where each
 * bulletin enters SpringBoard. It then explicitly asks AudioToolbox for a
 * vibration, independent of whether iOS decides to suppress the native haptic.
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

static NSString *ENVString(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSString *ENVSectionIDFromBulletin(id bulletin) {
    if (!bulletin) return nil;

    NSString *sectionID = nil;
    if ([bulletin respondsToSelector:@selector(sectionID)]) {
        sectionID = ENVString([bulletin sectionID]);
    }

    // Some older BulletinBoard objects expose `section` instead of sectionID.
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

    // Ignore objects without an app/section identifier.
    if (ENVSectionIDFromBulletin(bulletin).length == 0) return NO;

    // Avoid vibrating for internal BulletinBoard bookkeeping updates that have
    // no visible notification content at all.
    NSArray<NSString *> *contentKeys = @[@"title", @"subtitle", @"message"];
    for (NSString *key in contentKeys) {
        @try {
            NSString *value = ENVString([bulletin valueForKey:key]);
            if (value.length > 0) return YES;
        } @catch (__unused NSException *e) {}
    }

    // Some apps can intentionally send a visible notification whose text is
    // private/empty. If it has a real bulletin ID, still count it.
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

static void ENVForceVibrationForBulletin(id bulletin, NSString *fallbackSectionID) {
    if (!bulletin) return;

    NSString *sectionID = ENVSectionIDFromBulletin(bulletin);
    if (sectionID.length == 0) sectionID = fallbackSectionID;
    if (sectionID.length == 0) return;

    if (!ENVLooksLikeUserNotification(bulletin)) return;

    NSString *key = ENVEventKey(bulletin, sectionID);
    if (!key) return;

    @synchronized (ENVRecentEvents) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSNumber *previous = ENVRecentEvents[key];

        // The same bulletin can pass through more than one hook below during
        // one delivery. Suppress only near-simultaneous duplicate callbacks.
        // A second Snapchat notification a second (or minutes) later still
        // triggers because it is outside this tiny window, even if Snapchat
        // reuses the same bulletin identifier for a grouped notification.
        if (previous && (now - previous.doubleValue) < ENVDuplicateWindow) {
            return;
        }

        ENVRecentEvents[key] = @(now);

        if (ENVRecentEvents.count > 512) {
            [ENVRecentEvents removeAllObjects];
            ENVRecentEvents[key] = @(now);
        }
    }

    // This uses the system vibration service rather than UIImpactFeedbackGenerator.
    // It is more appropriate for a SpringBoard notification arriving while the
    // phone is locked/backgrounded.
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

/*
 * Primary iOS 16 path.
 * Reverse-engineered iOS notification traces show incoming bulletins going
 * through NCBulletinNotificationSource before NCNotificationDispatcher and the
 * banner/lock-screen destinations.
 */
%hook NCBulletinNotificationSource

- (void)observer:(id)observer
     addBulletin:(id)bulletin
         forFeed:(unsigned long long)feed
playLightsAndSirens:(BOOL)playLightsAndSirens
       withReply:(id)reply {

    // Force the vibration regardless of Apple's playLightsAndSirens decision.
    // That is intentional: repeated/coalesced alerts are what we're fixing.
    ENVForceVibrationForBulletin(bulletin, nil);
    %orig;
}

%end

/*
 * Fallback BulletinBoard hooks. These are kept because iOS point releases can
 * route a bulletin slightly differently. The 350 ms event de-duplicator above
 * prevents the primary + fallback paths from causing two tweak vibrations for
 * the same delivery.
 */
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
    }
}
