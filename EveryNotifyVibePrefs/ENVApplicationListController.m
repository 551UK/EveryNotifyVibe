#import "ENVApplicationListController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static CFStringRef const ENVPrefsDomain = CFSTR("com.local.everynotifyvibe.preferences");
static CFStringRef const ENVReloadNotification = CFSTR("com.local.everynotifyvibe.preferences/ReloadPrefs");

@interface NSObject (ENVLaunchServices)
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
@end

@implementation ENVApplicationListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Applications";
}

- (NSArray *)installedApplications {
    if (_applications) return _applications;

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }

    if (!workspaceClass || ![workspaceClass respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) {
        _applications = @[];
        return _applications;
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
    NSArray *rawApps = nil;

    if ([workspace respondsToSelector:NSSelectorFromString(@"allInstalledApplications")]) {
        rawApps = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allInstalledApplications"));
    } else if ([workspace respondsToSelector:NSSelectorFromString(@"allApplications")]) {
        rawApps = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allApplications"));
    }

    NSMutableArray *apps = [NSMutableArray array];
    for (id app in rawApps ?: @[]) {
        NSString *bundleID = [app respondsToSelector:@selector(applicationIdentifier)] ? [app applicationIdentifier] : nil;
        NSString *name = [app respondsToSelector:@selector(localizedName)] ? [app localizedName] : nil;

        if (bundleID.length > 0 && name.length > 0) {
            [apps addObject:app];
        }
    }

    [apps sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a localizedName] localizedCaseInsensitiveCompare:[b localizedName]];
    }];

    _applications = [apps copy];
    return _applications;
}

- (void)loadDisabledApps {
    [_disabledApps removeAllObjects];
    if (!_disabledApps) _disabledApps = [NSMutableSet set];

    CFPreferencesSynchronize(
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    CFPropertyListRef value = CFPreferencesCopyValue(
        CFSTR("DisabledApps"),
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        for (id item in (__bridge NSArray *)value) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                [_disabledApps addObject:item];
            }
        }
    }

    if (value) CFRelease(value);
}

- (void)saveDisabledApps {
    NSArray *sorted = [[_disabledApps allObjects] sortedArrayUsingSelector:@selector(compare:)];

    CFPreferencesSetValue(
        CFSTR("DisabledApps"),
        (__bridge CFArrayRef)sorted,
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    CFPreferencesSynchronize(
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        ENVReloadNotification,
        NULL,
        NULL,
        true
    );
}

- (PSSpecifier *)specifierForApplication:(id)app {
    NSString *bundleID = [app applicationIdentifier];
    NSString *name = [app localizedName];

    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                             target:self
                                                                set:@selector(setApplicationEnabled:specifier:)
                                                                get:@selector(applicationEnabled:)
                                                             detail:Nil
                                                               cell:PSSwitchCell
                                                               edit:Nil];
    [specifier setProperty:bundleID forKey:@"ENVBundleIdentifier"];
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    _disabledApps = [NSMutableSet set];
    [self loadDisabledApps];

    NSMutableArray *result = [NSMutableArray array];

    PSSpecifier *bulkGroup = [PSSpecifier groupSpecifierWithName:@"All Apps"];
    [bulkGroup setProperty:@"Apps are enabled by default. Disable an app to leave its notification vibration completely to stock iOS." forKey:@"footerText"];
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

    NSArray *apps = [self installedApplications];
    if (apps.count > 0) {
        [result addObject:[PSSpecifier groupSpecifierWithName:@"Applications"]];
        for (id app in apps) {
            [result addObject:[self specifierForApplication:app]];
        }
    } else {
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:@"Unable to read the installed application list." forKey:@"footerText"];
        [result addObject:group];
    }

    _specifiers = result;
    return _specifiers;
}

- (id)applicationEnabled:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"ENVBundleIdentifier"];
    return @(![_disabledApps containsObject:bundleID]);
}

- (void)setApplicationEnabled:(NSNumber *)enabled specifier:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"ENVBundleIdentifier"];
    if (bundleID.length == 0) return;

    if (enabled.boolValue) {
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

    for (id app in [self installedApplications]) {
        NSString *bundleID = [app applicationIdentifier];
        if (bundleID.length > 0) [_disabledApps addObject:bundleID];
    }

    [self saveDisabledApps];
    [self reloadSpecifiers];
}

@end
