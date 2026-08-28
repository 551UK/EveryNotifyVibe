#import <Preferences/PSListController.h>

@interface ENVApplicationListController : PSListController {
    NSMutableSet<NSString *> *_disabledApps;
    NSArray *_applications;
}
@end
