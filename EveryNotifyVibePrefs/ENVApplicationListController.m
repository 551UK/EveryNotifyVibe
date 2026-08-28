#import "ENVApplicationListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static CFStringRef const ENVPreferencesDomain = CFSTR("com.local.everynotifyvibe.preferences");
static CFStringRef const ENVPreferencesChangedNotification = CFSTR("com.local.everynotifyvibe.preferences/ReloadPrefs");

@interface NSObject (ENVLaunchServices)
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

@interface UIImage (ENVPrivateAppIcon)
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                                   format:(int)format
                                                    scale:(CGFloat)scale;
@end

@implementation ENVApplicationListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Applications";
}

- (Class)launchServicesWorkspaceClass {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) return workspaceClass;

    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) return workspaceClass;

    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    return NSClassFromString(@"LSApplicationWorkspace");
}

- (NSArray *)installedApplicationProxies {
    if (_applicationProxies) return _applicationProxies;

    Class workspaceClass = [self launchServicesWorkspaceClass];
    if (!workspaceClass || ![workspaceClass respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) {
        _applicationProxies = @[];
        return _applicationProxies;
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
    NSArray *apps = nil;

    if ([workspace respondsToSelector:NSSelectorFromString(@"allApplications")]) {
        apps = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allApplications"));
    }
    if (apps.count == 0 && [workspace respondsToSelector:NSSelectorFromString(@"allInstalledApplications")]) {
        apps = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allInstalledApplications"));
    }

    NSMutableArray *validApps = [NSMutableArray array];
    for (id proxy in apps ?: @[]) {
        NSString *bundleID = nil;
        NSString *name = nil;

        if ([proxy respondsToSelector:@selector(applicationIdentifier)]) {
            bundleID = [proxy applicationIdentifier];
        }
        if ([proxy respondsToSelector:@selector(localizedName)]) {
            name = [proxy localizedName];
        }

        if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) continue;
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;


        [validApps addObject:proxy];
    }

    [validApps sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *nameA = [a respondsToSelector:@selector(localizedName)] ? [a localizedName] : @"";
        NSString *nameB = [b respondsToSelector:@selector(localizedName)] ? [b localizedName] : @"";
        return [nameA localizedCaseInsensitiveCompare:nameB];
    }];

    _applicationProxies = [validApps copy];
    return _applicationProxies;
}

- (void)loadDisabledApps {
    CFPreferencesAppSynchronize(ENVPreferencesDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("DisabledApps"), ENVPreferencesDomain);

    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        _disabledApps = [NSMutableSet setWithArray:(__bridge NSArray *)value];
    } else {
        _disabledApps = [NSMutableSet set];
    }

    if (value) CFRelease(value);
}

- (void)saveDisabledApps {
    NSArray *sorted = [[_disabledApps allObjects] sortedArrayUsingSelector:@selector(compare:)];
    CFPreferencesSetAppValue(CFSTR("DisabledApps"), (__bridge CFArrayRef)sorted, ENVPreferencesDomain);
    CFPreferencesAppSynchronize(ENVPreferencesDomain);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        ENVPreferencesChangedNotification,
        NULL,
        NULL,
        true
    );
}

- (BOOL)isSystemApplication:(id)proxy {
    NSString *type = nil;
    NSString *bundleID = nil;

    if ([proxy respondsToSelector:@selector(applicationType)]) type = [proxy applicationType];
    if ([proxy respondsToSelector:@selector(applicationIdentifier)]) bundleID = [proxy applicationIdentifier];

    if ([type isKindOfClass:[NSString class]] && [type caseInsensitiveCompare:@"System"] == NSOrderedSame) {
        return YES;
    }
    return [bundleID hasPrefix:@"com.apple."];
}

- (PSSpecifier *)applicationSpecifierForProxy:(id)proxy {
    NSString *bundleID = [proxy applicationIdentifier];
    NSString *name = [proxy localizedName];

    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                             target:self
                                                                set:@selector(setApplicationEnabled:specifier:)
                                                                get:@selector(readApplicationEnabled:)
                                                             detail:Nil
                                                               cell:PSSwitchCell
                                                               edit:Nil];
    [specifier setProperty:bundleID forKey:@"applicationIdentifier"];

    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID
                                                                   format:0
                                                                    scale:[UIScreen mainScreen].scale];
        if (icon) [specifier setProperty:icon forKey:@"iconImage"];
    }

    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    [self loadDisabledApps];
    NSArray *apps = [self installedApplicationProxies];
    NSMutableArray *result = [NSMutableArray array];

    PSSpecifier *bulkGroup = [PSSpecifier groupSpecifierWithName:@"Bulk Controls"];
    [bulkGroup setProperty:@"All applications are enabled for EveryNotifyVibe by default. Use these buttons to quickly switch every listed app on or off." forKey:@"footerText"];
    [result addObject:bulkGroup];

    PSSpecifier *enableAll = [PSSpecifier preferenceSpecifierNamed:@"Enable All Apps"
                                                             target:self
                                                                set:NULL
                                                                get:NULL
                                                             detail:Nil
                                                               cell:PSButtonCell
                                                               edit:Nil];
    enableAll.buttonAction = @selector(enableAllApps);
    [result addObject:enableAll];

    PSSpecifier *disableAll = [PSSpecifier preferenceSpecifierNamed:@"Disable All Apps"
                                                              target:self
                                                                 set:NULL
                                                                 get:NULL
                                                              detail:Nil
                                                                cell:PSButtonCell
                                                                edit:Nil];
    disableAll.buttonAction = @selector(disableAllApps);
    [result addObject:disableAll];

    NSMutableArray *userApps = [NSMutableArray array];
    NSMutableArray *systemApps = [NSMutableArray array];

    for (id proxy in apps) {
        PSSpecifier *specifier = [self applicationSpecifierForProxy:proxy];
        if ([self isSystemApplication:proxy]) {
            [systemApps addObject:specifier];
        } else {
            [userApps addObject:specifier];
        }
    }

    if (userApps.count > 0) {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"User Apps"];
        [group setProperty:@"Turn an app off to disable every-notification vibration for that app. EveryNotifyVibe then follows iOS's normal alert flag: the first alert can vibrate, while rapid/grouped follow-ups may remain silent." forKey:@"footerText"];
        [result addObject:group];
        [result addObjectsFromArray:userApps];
    }

    if (systemApps.count > 0) {
        [result addObject:[PSSpecifier groupSpecifierWithName:@"Apple & System Apps"]];
        [result addObjectsFromArray:systemApps];
    }

    if (apps.count == 0) {
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:@"EveryNotifyVibe could not read the installed application list. The master switch will still work." forKey:@"footerText"];
        [result addObject:group];
    }

    _specifiers = result;
    return _specifiers;
}

- (id)readApplicationEnabled:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"applicationIdentifier"];
    if (bundleID.length == 0) return @YES;
    return @(![_disabledApps containsObject:bundleID]);
}

- (void)setApplicationEnabled:(NSNumber *)enabled specifier:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"applicationIdentifier"];
    if (bundleID.length == 0) return;

    if ([enabled boolValue]) {
        [_disabledApps removeObject:bundleID];
    } else {
        [_disabledApps addObject:bundleID];
    }

    [self saveDisabledApps];
}

- (void)enableAllApps {
    [_disabledApps removeAllObjects];
    [self saveDisabledApps];
    [self reloadSpecifiers];
}

- (void)disableAllApps {
    [_disabledApps removeAllObjects];
    for (id proxy in [self installedApplicationProxies]) {
        NSString *bundleID = [proxy respondsToSelector:@selector(applicationIdentifier)] ? [proxy applicationIdentifier] : nil;
        if (bundleID.length > 0) [_disabledApps addObject:bundleID];
    }
    [self saveDisabledApps];
    [self reloadSpecifiers];
}

@end
