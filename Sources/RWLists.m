#import "RWUI.h"

#pragma mark - Cell

@implementation RWVideoCell {
    UIImageView *_thumb;
    UILabel *_duration;
    UILabel *_title;
    UILabel *_meta;
    NSURL *_imageURL;
    BOOL _round;
}

+ (BOOL)isPad { return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad; }
+ (CGFloat)rowHeight { return [self isPad] ? 118 : 96; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _thumb = [UIImageView new];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1];
        _thumb.layer.cornerRadius = 4;
        [self.contentView addSubview:_thumb];

        _duration = [UILabel new];
        _duration.font = [UIFont boldSystemFontOfSize:11];
        _duration.textColor = [UIColor whiteColor];
        _duration.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        _duration.textAlignment = NSTextAlignmentCenter;
        _duration.layer.cornerRadius = 3;
        _duration.clipsToBounds = YES;
        [_thumb addSubview:_duration];

        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _title.numberOfLines = 2;
        [self.contentView addSubview:_title];

        _meta = [UILabel new];
        _meta.font = [UIFont systemFontOfSize:12];
        _meta.textColor = [UIColor grayColor];
        _meta.numberOfLines = 2;
        [self.contentView addSubview:_meta];
    }
    return self;
}

- (void)setImageURL:(NSURL *)url {
    _imageURL = url;
    _thumb.image = nil;
    __weak RWVideoCell *weakSelf = self;
    [[RWNetwork shared] loadImage:url completion:^(UIImage *image) {
        RWVideoCell *cell = weakSelf;
        if (cell && [cell->_imageURL isEqual:url]) cell->_thumb.image = image;
    }];
}

- (void)configureWithVideo:(RWVideo *)video {
    _round = NO;
    _title.text = video.title;
    _meta.text = video.metaText;
    NSString *duration = video.durationText;
    _duration.hidden = duration == nil;
    _duration.text = duration ? [NSString stringWithFormat:@" %@ ", duration] : nil;
    _duration.backgroundColor = video.live ? RWTintColor() : [UIColor colorWithWhite:0 alpha:0.8];
    [self setImageURL:video.thumbnailURL];
    [self setNeedsLayout];
}

- (void)configureWithChannel:(RWChannel *)channel {
    _round = YES;
    _title.text = channel.name;
    _meta.text = channel.subText ?: @"Channel";
    _duration.hidden = YES;
    [self setImageURL:channel.avatarURL];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat pad = 10;
    CGFloat thumbH = b.size.height - pad * 2;
    CGFloat thumbW = floor(thumbH * 16 / 9);
    if (_round) {
        CGFloat d = thumbH;
        _thumb.frame = CGRectMake(pad + (thumbW - d) / 2, pad, d, d);
        _thumb.layer.cornerRadius = d / 2;
    } else {
        _thumb.frame = CGRectMake(pad, pad, thumbW, thumbH);
        _thumb.layer.cornerRadius = 4;
    }
    [_duration sizeToFit];
    CGSize ds = _duration.bounds.size;
    _duration.frame = CGRectMake(_thumb.bounds.size.width - ds.width - 4, _thumb.bounds.size.height - ds.height - 6, ds.width, ds.height + 2);

    CGFloat x = pad + thumbW + 12;
    CGFloat w = b.size.width - x - pad;
    CGSize ts = [_title sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    CGFloat titleH = MIN(ts.height, ceil(_title.font.lineHeight * 2));
    CGSize ms = [_meta sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    CGFloat metaH = MIN(ms.height, ceil(_meta.font.lineHeight * 2));
    CGFloat total = titleH + 4 + metaH;
    CGFloat y = MAX(pad, floor((b.size.height - total) / 2));
    _title.frame = CGRectMake(x, y, w, titleH);
    _meta.frame = CGRectMake(x, y + titleH + 4, w, metaH);
}

@end

#pragma mark - List

@implementation RWListViewController {
    NSMutableArray *_items;
    NSString *_next;
    NSUInteger _generation;
    BOOL _loading;
    BOOL _loadedOnce;
    BOOL _dirty;
    UIActivityIndicatorView *_footerSpinner;
}

- (instancetype)initWithTitle:(NSString *)title loader:(RWListLoader)loader {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = title;
        _loader = [loader copy];
        _items = [NSMutableArray array];
        _loadsOnAppear = YES;
    }
    return self;
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    return [self initWithTitle:nil loader:nil];
}

- (NSArray *)items { return _items; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = [RWVideoCell rowHeight];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 10, 0, 0);
    [self.tableView registerClass:[RWVideoCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.tableFooterView = [UIView new];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    _footerSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _footerSpinner.frame = CGRectMake(0, 0, 44, 50);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(libraryChanged) name:RWLibraryDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.loadsOnAppear && (!_loadedOnce || _dirty)) { _dirty = NO; [self reload]; }
}

- (void)libraryChanged {
    if (!self.reloadOnLibraryChange) return;
    if (self.isViewLoaded && self.view.window) [self reload];
    else _dirty = YES;
}

- (void)showMessage:(NSString *)message {
    if (!message) { self.tableView.backgroundView = nil; return; }
    UILabel *label = [UILabel new];
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor grayColor];
    label.font = [UIFont systemFontOfSize:15];
    UIView *wrap = [UIView new];
    [wrap addSubview:label];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:wrap.centerYAnchor constant:-40],
        [label.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:32],
        [label.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-32],
    ]];
    self.tableView.backgroundView = wrap;
}

- (void)reload {
    if (!self.loader) { [self.refreshControl endRefreshing]; return; }
    _loadedOnce = YES;
    NSUInteger gen = ++_generation;
    _loading = YES;
    if (!_items.count) {
        UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        [spin startAnimating];
        self.tableView.backgroundView = spin;
    }
    __weak RWListViewController *weakSelf = self;
    self.loader(nil, ^(NSArray *items, NSString *next, NSError *error) {
        RWListViewController *s = weakSelf;
        if (!s || gen != s->_generation) return;
        s->_loading = NO;
        [s.refreshControl endRefreshing];
        if (error && !items.count) {
            if (!s->_items.count) [s showMessage:[NSString stringWithFormat:@"Couldn't load.\n\n%@", error.localizedDescription]];
            else RWShowAlert(s, @"Couldn't refresh", error.localizedDescription);
            return;
        }
        s->_items = [NSMutableArray arrayWithArray:items ?: @[]];
        s->_next = next;
        [s.tableView reloadData];
        [s showMessage:s->_items.count ? nil : s.emptyText];
    });
}

- (void)loadMore {
    if (_loading || !_next || !self.loader) return;
    _loading = YES;
    NSUInteger gen = _generation;
    [_footerSpinner startAnimating];
    self.tableView.tableFooterView = _footerSpinner;
    __weak RWListViewController *weakSelf = self;
    self.loader(_next, ^(NSArray *items, NSString *next, NSError *error) {
        RWListViewController *s = weakSelf;
        if (!s || gen != s->_generation) return;
        s->_loading = NO;
        [s->_footerSpinner stopAnimating];
        s.tableView.tableFooterView = [UIView new];
        if (!items.count) { s->_next = nil; return; }
        NSMutableArray *paths = [NSMutableArray array];
        for (id item in items) {
            [paths addObject:[NSIndexPath indexPathForRow:s->_items.count inSection:0]];
            [s->_items addObject:item];
        }
        s->_next = next;
        [s.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _items.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RWVideoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    id item = _items[indexPath.row];
    if ([item isKindOfClass:[RWChannel class]]) [cell configureWithChannel:item];
    else [cell configureWithVideo:item];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row + 5 >= (NSInteger)_items.count) [self loadMore];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id item = _items[indexPath.row];
    UIViewController *next = [item isKindOfClass:[RWChannel class]]
        ? [[RWChannelViewController alloc] initWithChannel:item]
        : [[RWPlayerViewController alloc] initWithVideo:item];
    [self.navigationController pushViewController:next animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.deleteHandler != nil || [_items[indexPath.row] isKindOfClass:[RWVideo class]];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {}

- (NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    id item = _items[indexPath.row];
    if (self.deleteHandler) {
        __weak RWListViewController *weakSelf = self;
        return @[[UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive title:@"Remove" handler:^(UITableViewRowAction *a, NSIndexPath *ip) {
            RWListViewController *s = weakSelf;
            if (!s || ip.row >= (NSInteger)s->_items.count) return;
            id target = s->_items[ip.row];
            [s->_items removeObjectAtIndex:ip.row];
            [s.tableView deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
            s.deleteHandler(target);
            if (!s->_items.count) [s showMessage:s.emptyText];
        }]];
    }
    RWVideo *video = item;
    BOOL saved = [RWLibrary isSaved:video.videoId];
    UITableViewRowAction *save = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal title:saved ? @"Unsave" : @"Save" handler:^(UITableViewRowAction *a, NSIndexPath *ip) {
        [RWLibrary toggleSaved:video];
        [tableView setEditing:NO animated:YES];
    }];
    save.backgroundColor = RWTintColor();
    return @[save];
}

@end

#pragma mark - Channel

@implementation RWChannelViewController {
    RWChannel *_channel;
    UIImageView *_avatar;
    UILabel *_name;
    UILabel *_subs;
    UIButton *_subscribe;
}

- (instancetype)initWithChannel:(RWChannel *)channel {
    NSString *ucid = channel.ucid;
    self = [super initWithTitle:channel.name loader:^(NSString *cursor, RWListDone done) {
        [RWAPI channelVideos:ucid continuation:cursor completion:done];
    }];
    if (self) {
        _channel = channel;
        self.emptyText = @"This channel has no videos.";
        self.hidesBottomBarWhenPushed = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 96)];
    _avatar = [[UIImageView alloc] initWithFrame:CGRectMake(16, 16, 64, 64)];
    _avatar.layer.cornerRadius = 32;
    _avatar.clipsToBounds = YES;
    _avatar.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1];
    [header addSubview:_avatar];
    _name = [UILabel new];
    _name.font = [UIFont boldSystemFontOfSize:18];
    _subs = [UILabel new];
    _subs.font = [UIFont systemFontOfSize:13];
    _subs.textColor = [UIColor grayColor];
    _subscribe = [UIButton buttonWithType:UIButtonTypeSystem];
    _subscribe.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _subscribe.layer.cornerRadius = 4;
    _subscribe.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [_subscribe addTarget:self action:@selector(toggleSubscribe) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *v in @[_name, _subs, _subscribe]) [header addSubview:v];
    _name.frame = CGRectMake(92, 18, header.bounds.size.width - 108, 24);
    _subs.frame = CGRectMake(92, 42, header.bounds.size.width - 108, 18);
    _name.autoresizingMask = _subs.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView = header;
    [self refreshHeader];

    __weak RWChannelViewController *weakSelf = self;
    [RWAPI channel:_channel.ucid completion:^(NSDictionary *info, NSError *error) {
        RWChannelViewController *s = weakSelf;
        RWChannel *full = [RWChannel channelWithDictionary:info];
        if (!s || !full) return;
        s->_channel = full;
        s.title = full.name;
        [s refreshHeader];
    }];
}

- (void)refreshHeader {
    _name.text = _channel.name;
    _subs.text = _channel.subText;
    BOOL subscribed = [RWLibrary isSubscribed:_channel.ucid];
    [_subscribe setTitle:subscribed ? @"SUBSCRIBED" : @"SUBSCRIBE" forState:UIControlStateNormal];
    _subscribe.backgroundColor = subscribed ? [UIColor colorWithWhite:0.92 alpha:1] : RWTintColor();
    [_subscribe setTitleColor:subscribed ? [UIColor darkGrayColor] : [UIColor whiteColor] forState:UIControlStateNormal];
    [_subscribe sizeToFit];
    _subscribe.frame = CGRectMake(92, 62, _subscribe.bounds.size.width, 26);
    __weak UIImageView *avatar = _avatar;
    [[RWNetwork shared] loadImage:_channel.avatarURL completion:^(UIImage *image) { if (image) avatar.image = image; }];
}

- (void)toggleSubscribe {
    [RWLibrary toggleSubscription:_channel];
    [self refreshHeader];
}

@end

#pragma mark - Search

@implementation RWSearchViewController {
    UISearchBar *_bar;
    NSString *_query;
}

- (instancetype)init {
    __block __weak RWSearchViewController *weakSelf = nil;
    self = [super initWithTitle:@"Search" loader:^(NSString *cursor, RWListDone done) {
        RWSearchViewController *s = weakSelf;
        if (!s || !s->_query.length) { done(@[], nil, nil); return; }
        NSString *type = s->_bar.selectedScopeButtonIndex == 1 ? @"channel" : @"video";
        [RWAPI search:s->_query type:type page:cursor ? cursor.integerValue : 1 completion:done];
    }];
    weakSelf = self;
    if (self) {
        self.emptyText = @"Search for videos and channels.";
        self.loadsOnAppear = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _bar = [UISearchBar new];
    _bar.placeholder = @"Search YouTube";
    _bar.delegate = self;
    _bar.scopeButtonTitles = @[@"Videos", @"Channels"];
    _bar.showsScopeBar = YES;
    _bar.searchBarStyle = UISearchBarStyleMinimal;
    [_bar sizeToFit];
    self.tableView.tableHeaderView = _bar;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.refreshControl = nil;
    [self showMessage:self.emptyText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    _query = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [searchBar resignFirstResponder];
    self.emptyText = @"No results.";
    [self reload];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    if (_query.length) [self reload];
}

@end

#pragma mark - Library

@implementation RWLibraryViewController {
    UISegmentedControl *_segment;
}

- (instancetype)init {
    __block __weak RWLibraryViewController *weakSelf = nil;
    self = [super initWithTitle:@"Library" loader:^(NSString *cursor, RWListDone done) {
        RWLibraryViewController *s = weakSelf;
        NSInteger seg = s ? s->_segment.selectedSegmentIndex : 0;
        if (seg == 1) done([RWLibrary history], nil, nil);
        else if (seg == 2) done([RWLibrary subscriptions], nil, nil);
        else done([RWLibrary saved], nil, nil);
    }];
    weakSelf = self;
    if (self) {
        self.reloadOnLibraryChange = YES;
        self.deleteHandler = ^(id item) {
            RWLibraryViewController *s = weakSelf;
            if ([item isKindOfClass:[RWChannel class]]) [RWLibrary removeSubscription:((RWChannel *)item).ucid];
            else if (s && s->_segment.selectedSegmentIndex == 1) [RWLibrary removeHistory:((RWVideo *)item).videoId];
            else [RWLibrary removeSaved:((RWVideo *)item).videoId];
        };
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _segment = [[UISegmentedControl alloc] initWithItems:@[@"Saved", @"History", @"Channels"]];
    _segment.selectedSegmentIndex = 0;
    [_segment addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _segment;
    self.refreshControl = nil;
    [self segmentChanged];
}

- (void)segmentChanged {
    NSInteger seg = _segment.selectedSegmentIndex;
    self.emptyText = seg == 0 ? @"Swipe left on any video and tap Save to keep it here."
                   : seg == 1 ? @"Videos you watch show up here."
                              : @"Channels you subscribe to show up here.";
    self.navigationItem.rightBarButtonItem = seg == 1
        ? [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clearHistory)]
        : nil;
    if (self.isViewLoaded) [self reload];
}

- (void)clearHistory {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Clear watch history?" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [RWLibrary clearHistory]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
