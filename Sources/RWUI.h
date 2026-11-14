#import "RWCore.h"

UIImage *RWIcon(NSString *name);   // "trending", "subs", "search", "library", "settings"
void RWShowAlert(UIViewController *vc, NSString *title, NSString *message);

@interface RWAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface RWVideoCell : UITableViewCell
+ (CGFloat)rowHeight;
- (void)configureWithVideo:(RWVideo *)video;
- (void)configureWithChannel:(RWChannel *)channel;
@end

typedef void (^RWListDone)(NSArray *items, NSString *next, NSError *error);
typedef void (^RWListLoader)(NSString *cursor, RWListDone done);

// A paged list of RWVideo / RWChannel items with pull-to-refresh and infinite scroll.
@interface RWListViewController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title loader:(RWListLoader)loader;
@property (nonatomic, copy) RWListLoader loader;
@property (nonatomic, copy) NSString *emptyText;
@property (nonatomic, strong, readonly) NSArray *items;
@property (nonatomic) BOOL reloadOnLibraryChange;
@property (nonatomic, copy) void (^deleteHandler)(id item);   // set to show "Remove" instead of "Save"
@property (nonatomic) BOOL loadsOnAppear;                      // default YES
- (void)reload;
- (void)showMessage:(NSString *)message;   // centered placeholder text, nil hides it
@end

@interface RWChannelViewController : RWListViewController
- (instancetype)initWithChannel:(RWChannel *)channel;
@end

@interface RWSearchViewController : RWListViewController <UISearchBarDelegate>
@end

@interface RWLibraryViewController : RWListViewController
@end

@interface RWSettingsViewController : UITableViewController <UITextFieldDelegate>
@end

@interface RWPlayerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithVideo:(RWVideo *)video;
@end
