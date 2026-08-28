#import "ENVApplicationListController.h"
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>

static CFStringRef const ENVPrefsDomain = CFSTR("com.local.everynotifyvibe.preferences");
static CFStringRef const ENVReloadNotification = CFSTR("com.local.everynotifyvibe.preferences/ReloadPrefs");

@interface NSObject (ENVLaunchServices)
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

@interface ENVApplicationListController ()
@property (nonatomic, retain) NSArray *applications;
@property (nonatomic, retain) NSArray *userApps;
@property (nonatomic, retain) NSArray *systemApps;
@property (nonatomic, retain) NSMutableSet *disabledApps;
@property (nonatomic, retain) UISearchController *envSearchController;
@property (nonatomic, copy) NSString *searchText;
@end

@implementation ENVApplicationListController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Applications";
    self.definesPresentationContext = YES;

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = @"Search Apps";
    searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.envSearchController = searchController;

    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Actions"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showBulkActions)];
}

#pragma mark - Installed applications

- (NSArray *)installedApplications {
    if (self.applications) return self.applications;

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }

    if (!workspaceClass || ![workspaceClass respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) {
        self.applications = @[];
        return self.applications;
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
    NSArray *rawApps = nil;

    if ([workspace respondsToSelector:NSSelectorFromString(@"allInstalledApplications")]) {
        rawApps = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allInstalledApplications"));
    } else if ([workspace respondsToSelector:NSSelectorFromString(@"allApplications")]) {
        rawApps = ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allApplications"));
    }

    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet *seenBundleIDs = [NSMutableSet set];

    for (id app in rawApps ?: @[]) {
        NSString *bundleID = [app respondsToSelector:@selector(applicationIdentifier)] ? [app applicationIdentifier] : nil;
        NSString *name = [app respondsToSelector:@selector(localizedName)] ? [app localizedName] : nil;

        if (bundleID.length == 0 || name.length == 0) continue;
        if ([seenBundleIDs containsObject:bundleID]) continue;

        // Keep the page focused on actual applications rather than extensions.
        NSString *lowerID = bundleID.lowercaseString;
        if ([lowerID containsString:@".appex"] ||
            [lowerID containsString:@".widget"] ||
            [lowerID containsString:@".intents"] ||
            [lowerID containsString:@".notificationservice"]) {
            continue;
        }

        [seenBundleIDs addObject:bundleID];
        [apps addObject:app];
    }

    [apps sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a localizedName] localizedCaseInsensitiveCompare:[b localizedName]];
    }];

    self.applications = [apps copy];
    return self.applications;
}

- (BOOL)isSystemApplication:(id)app {
    if ([app respondsToSelector:@selector(applicationType)]) {
        NSString *type = [app applicationType];
        if ([type isKindOfClass:[NSString class]]) {
            if ([type caseInsensitiveCompare:@"System"] == NSOrderedSame) return YES;
            if ([type caseInsensitiveCompare:@"User"] == NSOrderedSame) return NO;
        }
    }

    NSString *bundleID = [app respondsToSelector:@selector(applicationIdentifier)] ? [app applicationIdentifier] : nil;
    return [bundleID hasPrefix:@"com.apple."];
}

- (void)buildSectionsIfNeeded {
    if (self.userApps && self.systemApps) return;

    NSMutableArray *user = [NSMutableArray array];
    NSMutableArray *system = [NSMutableArray array];

    for (id app in [self installedApplications]) {
        if ([self isSystemApplication:app]) {
            [system addObject:app];
        } else {
            [user addObject:app];
        }
    }

    self.userApps = [user copy];
    self.systemApps = [system copy];
}

#pragma mark - Preferences

- (void)loadDisabledApps {
    if (!self.disabledApps) self.disabledApps = [NSMutableSet set];
    [self.disabledApps removeAllObjects];

    CFPreferencesSynchronize(ENVPrefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    CFPropertyListRef value = CFPreferencesCopyValue(
        CFSTR("DisabledApps"),
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        for (id item in (__bridge NSArray *)value) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                [self.disabledApps addObject:item];
            }
        }
    }

    if (value) CFRelease(value);
}

- (void)saveDisabledApps {
    NSArray *sorted = [[self.disabledApps allObjects] sortedArrayUsingSelector:@selector(compare:)];

    CFPreferencesSetValue(
        CFSTR("DisabledApps"),
        (__bridge CFArrayRef)sorted,
        ENVPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    CFPreferencesSynchronize(ENVPrefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        ENVReloadNotification,
        NULL,
        NULL,
        true
    );
}

#pragma mark - App icons

- (UIImage *)iconForBundleIdentifier:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;

    Class imageClass = [UIImage class];
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");

    if ([imageClass respondsToSelector:selector]) {
        typedef UIImage *(*ENVIconFunction)(id, SEL, NSString *, NSInteger, CGFloat);
        CGFloat scale = UIScreen.mainScreen.scale;
        UIImage *icon = ((ENVIconFunction)objc_msgSend)(imageClass, selector, bundleID, 2, scale > 0 ? scale : 3.0);
        if (icon) return icon;
    }

    return nil;
}

#pragma mark - Search

- (NSArray *)filteredApplications:(NSArray *)apps {
    NSString *query = [self.searchText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) return apps;

    NSMutableArray *matches = [NSMutableArray array];
    for (id app in apps) {
        NSString *name = [app respondsToSelector:@selector(localizedName)] ? [app localizedName] : @"";
        NSString *bundleID = [app respondsToSelector:@selector(applicationIdentifier)] ? [app applicationIdentifier] : @"";

        BOOL nameMatch = [name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
        BOOL bundleMatch = [bundleID rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;

        if (nameMatch || bundleMatch) [matches addObject:app];
    }

    return matches;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *newText = searchController.searchBar.text ?: @"";
    if ((self.searchText == nil && newText.length == 0) || [self.searchText isEqualToString:newText]) return;

    self.searchText = newText;
    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark - Specifiers

- (NSUInteger)enabledCountForApps:(NSArray *)apps {
    NSUInteger enabled = 0;
    for (id app in apps) {
        NSString *bundleID = [app applicationIdentifier];
        if (bundleID.length > 0 && ![self.disabledApps containsObject:bundleID]) enabled++;
    }
    return enabled;
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

    UIImage *icon = [self iconForBundleIdentifier:bundleID];
    if (icon) [specifier setProperty:icon forKey:@"iconImage"];

    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    if (!self.disabledApps) {
        self.disabledApps = [NSMutableSet set];
        [self loadDisabledApps];
    }

    [self buildSectionsIfNeeded];

    NSArray *visibleUserApps = [self filteredApplications:self.userApps ?: @[]];
    NSArray *visibleSystemApps = [self filteredApplications:self.systemApps ?: @[]];
    NSMutableArray *result = [NSMutableArray array];

    if (visibleUserApps.count > 0) {
        NSUInteger enabled = [self enabledCountForApps:self.userApps];
        NSString *footer = self.searchText.length > 0
            ? [NSString stringWithFormat:@"%lu matching app%@. Search also matches bundle IDs.", (unsigned long)visibleUserApps.count, visibleUserApps.count == 1 ? @"" : @"s"]
            : [NSString stringWithFormat:@"Third-party apps • %lu of %lu enabled.", (unsigned long)enabled, (unsigned long)self.userApps.count];

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Applications"];
        [group setProperty:footer forKey:@"footerText"];
        [result addObject:group];

        for (id app in visibleUserApps) [result addObject:[self specifierForApplication:app]];
    }

    if (visibleSystemApps.count > 0) {
        NSUInteger enabled = [self enabledCountForApps:self.systemApps];
        NSString *footer = self.searchText.length > 0
            ? [NSString stringWithFormat:@"%lu matching system app%@.", (unsigned long)visibleSystemApps.count, visibleSystemApps.count == 1 ? @"" : @"s"]
            : [NSString stringWithFormat:@"Built-in/system apps • %lu of %lu enabled.", (unsigned long)enabled, (unsigned long)self.systemApps.count];

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"System Apps"];
        [group setProperty:footer forKey:@"footerText"];
        [result addObject:group];

        for (id app in visibleSystemApps) [result addObject:[self specifierForApplication:app]];
    }

    if (result.count == 0) {
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        NSString *message = self.searchText.length > 0
            ? [NSString stringWithFormat:@"No apps found for “%@”.", self.searchText]
            : @"Unable to read the installed application list.";
        [group setProperty:message forKey:@"footerText"];
        [result addObject:group];
    }

    _specifiers = [result copy];
    return _specifiers;
}

- (id)applicationEnabled:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"ENVBundleIdentifier"];
    return @(![self.disabledApps containsObject:bundleID]);
}

- (void)setApplicationEnabled:(NSNumber *)enabled specifier:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"ENVBundleIdentifier"];
    if (bundleID.length == 0) return;

    if (enabled.boolValue) {
        [self.disabledApps removeObject:bundleID];
    } else {
        [self.disabledApps addObject:bundleID];
    }

    [self saveDisabledApps];
}

#pragma mark - Bulk controls

- (void)setApplications:(NSArray *)apps enabled:(BOOL)enabled {
    for (id app in apps) {
        NSString *bundleID = [app applicationIdentifier];
        if (bundleID.length == 0) continue;

        if (enabled) {
            [self.disabledApps removeObject:bundleID];
        } else {
            [self.disabledApps addObject:bundleID];
        }
    }

    [self saveDisabledApps];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)enableAllApps {
    [self.disabledApps removeAllObjects];
    [self saveDisabledApps];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)disableAllApps {
    [self setApplications:[self installedApplications] enabled:NO];
}

- (void)enableUserApps {
    [self setApplications:self.userApps ?: @[] enabled:YES];
}

- (void)disableUserApps {
    [self setApplications:self.userApps ?: @[] enabled:NO];
}

- (void)enableSystemApps {
    [self setApplications:self.systemApps ?: @[] enabled:YES];
}

- (void)disableSystemApps {
    [self setApplications:self.systemApps ?: @[] enabled:NO];
}

- (void)showBulkActions {
    [self buildSectionsIfNeeded];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"App Controls"
                                                                   message:@"Choose which groups EveryNotifyVibe should force vibrations for."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Enable All Apps"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) { [self enableAllApps]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Disable All Apps"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) { [self disableAllApps]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Enable Applications"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) { [self enableUserApps]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Disable Applications"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) { [self disableUserApps]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Enable System Apps"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) { [self enableSystemApps]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Disable System Apps"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) { [self disableSystemApps]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.barButtonItem = self.navigationItem.rightBarButtonItem;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

@end
