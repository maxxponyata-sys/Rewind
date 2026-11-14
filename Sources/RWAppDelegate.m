#import "RWUI.h"

void RWShowAlert(UIViewController *vc, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

UIImage *RWIcon(NSString *name) {
    CGSize size = CGSizeMake(25, 25);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [[UIColor blackColor] set];
    UIBezierPath *p = [UIBezierPath bezierPath];
    p.lineWidth = 2;
    p.lineCapStyle = kCGLineCapRound;
    p.lineJoinStyle = kCGLineJoinRound;

    if ([name isEqualToString:@"trending"]) {
        [p moveToPoint:CGPointMake(3, 19)];
        [p addLineToPoint:CGPointMake(9, 12)];
        [p addLineToPoint:CGPointMake(13, 16)];
        [p addLineToPoint:CGPointMake(21, 7)];
        [p moveToPoint:CGPointMake(15.5, 7)];
        [p addLineToPoint:CGPointMake(21, 7)];
        [p addLineToPoint:CGPointMake(21, 12.5)];
        [p stroke];
    } else if ([name isEqualToString:@"subs"]) {
        UIBezierPath *box = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 8, 19, 14) cornerRadius:3];
        box.lineWidth = 2; [box stroke];
        [p moveToPoint:CGPointMake(6, 4.5)]; [p addLineToPoint:CGPointMake(19, 4.5)];
        [p stroke];
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:CGPointMake(10.5, 11.5)];
        [tri addLineToPoint:CGPointMake(16, 15)];
        [tri addLineToPoint:CGPointMake(10.5, 18.5)];
        [tri closePath]; [tri fill];
    } else if ([name isEqualToString:@"search"]) {
        UIBezierPath *c = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(3.5, 3.5, 13, 13)];
        c.lineWidth = 2; [c stroke];
        p.lineWidth = 2.5;
        [p moveToPoint:CGPointMake(15, 15)]; [p addLineToPoint:CGPointMake(21.5, 21.5)];
        [p stroke];
    } else if ([name isEqualToString:@"library"]) {
        [p moveToPoint:CGPointMake(6, 3)];
        [p addLineToPoint:CGPointMake(19, 3)];
        [p addLineToPoint:CGPointMake(19, 22)];
        [p addLineToPoint:CGPointMake(12.5, 17)];
        [p addLineToPoint:CGPointMake(6, 22)];
        [p closePath];
        [p stroke];
    } else if ([name isEqualToString:@"settings"]) {
        CGPoint c = CGPointMake(12.5, 12.5);
        UIBezierPath *gear = [UIBezierPath bezierPath];
        for (int i = 0; i < 8; i++) {
            CGFloat a = (CGFloat)(i * M_PI / 4.0);
            UIBezierPath *tooth = [UIBezierPath bezierPathWithRect:CGRectMake(-2, -10.5, 4, 5)];
            CGAffineTransform t = CGAffineTransformMakeTranslation(c.x, c.y);
            t = CGAffineTransformRotate(t, a);
            [tooth applyTransform:t];
            [gear appendPath:tooth];
        }
        [gear appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - 7, c.y - 7, 14, 14)]];
        [gear fill];
        [[UIColor clearColor] set];
        CGContextSetBlendMode(UIGraphicsGetCurrentContext(), kCGBlendModeClear);
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - 3, c.y - 3, 6, 6)] fill];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@implementation RWAppDelegate

static UINavigationController *RWNav(UIViewController *vc, NSString *title, NSString *icon) {
    vc.title = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:RWIcon(icon) tag:0];
    return nav;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];

    RWListViewController *trending = [[RWListViewController alloc] initWithTitle:@"Trending" loader:^(NSString *cursor, RWListDone done) {
        [RWAPI trending:done];
    }];
    trending.emptyText = @"Nothing trending right now.";

    RWListViewController *subs = [[RWListViewController alloc] initWithTitle:@"Subscriptions" loader:^(NSString *cursor, RWListDone done) {
        [RWAPI subscriptionFeed:done];
    }];
    subs.emptyText = @"Subscribe to channels and their newest videos show up here.\n\nYour subscriptions stay on this device — no account needed.";
    subs.reloadOnLibraryChange = YES;

    UITabBarController *tabs = [UITabBarController new];
    tabs.viewControllers = @[
        RWNav(trending, @"Trending", @"trending"),
        RWNav(subs, @"Subscriptions", @"subs"),
        RWNav([RWSearchViewController new], @"Search", @"search"),
        RWNav([RWLibraryViewController new], @"Library", @"library"),
        RWNav([[RWSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped], @"Settings", @"settings"),
    ];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = RWTintColor();
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([RWAppDelegate class]));
    }
}
