#import <UIKit/UIKit.h>

/*
 * EveryNotifyVibe
 * ----------------
 * SpringBoard-only tweak for iOS 15/16 rootless jailbreaks.
 *
 * The notification hooks below are the iOS 16-style methods used by
 * NCNotificationCombinedListViewController. We deliberately call %orig first
 * and only add our haptic afterwards, so normal notification handling remains
 * untouched.
 */

@interface NCNotificationRequest : NSObject
@property (nonatomic, readonly, copy) NSString *notificationIdentifier;
@end

static NSMutableDictionary<NSString *, NSNumber *> *ENVLastFireTimes;
static UIImpactFeedbackGenerator *ENVHapticGenerator;

// Filters duplicate internal callbacks for the exact same request while still
// allowing repeated/coalesced alerts a moment later to vibrate normally.
static const NSTimeInterval ENVDebounceSeconds = 0.12;

static NSString *ENVKeyForRequest(NCNotificationRequest *request) {
    if (!request) {
        return nil;
    }

    NSString *identifier = nil;
    if ([request respondsToSelector:@selector(notificationIdentifier)]) {
        identifier = request.notificationIdentifier;
    }

    if (identifier.length > 0) {
        return identifier;
    }

    // Fallback for unusual requests that do not expose an identifier.
    return [NSString stringWithFormat:@"request-%p", request];
}

static void ENVFireHapticForRequest(NCNotificationRequest *request) {
    if (!request) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ENVLastFireTimes) {
            ENVLastFireTimes = [NSMutableDictionary dictionary];
        }

        NSString *key = ENVKeyForRequest(request);
        if (!key) {
            return;
        }

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSNumber *lastFire = ENVLastFireTimes[key];

        if (lastFire && (now - lastFire.doubleValue) < ENVDebounceSeconds) {
            return;
        }

        ENVLastFireTimes[key] = @(now);

        // Keep memory usage tiny even after long SpringBoard uptimes.
        if (ENVLastFireTimes.count > 256) {
            [ENVLastFireTimes removeAllObjects];
            ENVLastFireTimes[key] = @(now);
        }

        if (!ENVHapticGenerator) {
            ENVHapticGenerator = [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleMedium];
        }

        [ENVHapticGenerator prepare];
        [ENVHapticGenerator impactOccurred];
    });
}

%hook NCNotificationCombinedListViewController

// A brand-new notification is inserted into Notification Center.
- (bool)insertNotificationRequest:(NCNotificationRequest *)request
         forCoalescedNotification:(id)coalescedNotification {
    bool result = %orig;
    ENVFireHapticForRequest(request);
    return result;
}

// An existing/coalesced notification is updated. This is the important path
// for repeated/grouped alerts (for example several Snapchat messages/snaps).
- (bool)modifyNotificationRequest:(NCNotificationRequest *)request
         forCoalescedNotification:(id)coalescedNotification {
    bool result = %orig;
    ENVFireHapticForRequest(request);
    return result;
}

%end

%ctor {
    @autoreleasepool {
        ENVLastFireTimes = [NSMutableDictionary dictionary];
    }
}
