#import "RWUI.h"
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>

static void *RWItemStatusContext = &RWItemStatusContext;

static NSArray *RWArray(id o) { return [o isKindOfClass:[NSArray class]] ? o : @[]; }

static NSInteger RWHeight(NSDictionary *f) {
    for (NSString *key in @[@"resolution", @"qualityLabel"]) {
        id v = f[key];
        if ([v isKindOfClass:[NSString class]] && [v integerValue] > 0) return [v integerValue];
    }
    id size = f[@"size"];
    if ([size isKindOfClass:[NSString class]]) {
        NSArray *wh = [size componentsSeparatedByString:@"x"];
        if (wh.count == 2) return [wh[1] integerValue];
    }
    return 0;
}

static BOOL RWHasURL(NSDictionary *f) {
    return [f isKindOfClass:[NSDictionary class]] && [f[@"url"] isKindOfClass:[NSString class]];
}

// Best H.264 MP4 at or below maxHeight; otherwise the smallest one available.
static NSDictionary *RWPickVideo(NSArray *formats, NSInteger maxHeight) {
    NSDictionary *best = nil, *smallest = nil;
    for (NSDictionary *f in formats) {
        if (!RWHasURL(f)) continue;
        NSString *type = [f[@"type"] description];
        if (![type hasPrefix:@"video/mp4"] || [type rangeOfString:@"avc1"].location == NSNotFound) continue;
        NSInteger h = RWHeight(f);
        if (h <= maxHeight && (!best || h > RWHeight(best))) best = f;
        if (!smallest || h < RWHeight(smallest)) smallest = f;
    }
    return best ?: smallest;
}

static NSDictionary *RWPickAudio(NSArray *formats) {
    NSDictionary *pick = nil;
    for (NSDictionary *f in formats) {
        if (!RWHasURL(f) || ![[f[@"type"] description] hasPrefix:@"audio/mp4"]) continue;
        NSDictionary *track = [f[@"audioTrack"] isKindOfClass:[NSDictionary class]] ? f[@"audioTrack"] : nil;
        BOOL isDefault = [track[@"isDefault"] boolValue] || [track[@"default"] boolValue];
        BOOL is140 = [[f[@"itag"] description] isEqualToString:@"140"];
        if (!pick) { pick = f; continue; }
        BOOL pickIs140 = [[pick[@"itag"] description] isEqualToString:@"140"];
        if ((is140 && !pickIs140) || (is140 == pickIs140 && isDefault)) pick = f;
    }
    return pick;
}

static CMTime RWUsableDuration(AVAssetTrack *track, AVAsset *asset, NSInteger fallbackSeconds) {
    CMTime d = track.timeRange.duration;
    if (CMTIME_IS_NUMERIC(d) && CMTimeGetSeconds(d) > 0.5) return d;
    d = asset.duration;
    if (CMTIME_IS_NUMERIC(d) && CMTimeGetSeconds(d) > 0.5) return d;
    return CMTimeMakeWithSeconds(MAX(fallbackSeconds, 1), 600);
}

@implementation RWPlayerViewController {
    RWVideo *_video;
    NSDictionary *_info;
    RWChannel *_channel;
    NSArray<RWVideo *> *_related;
    NSString *_description;

    AVPlayerViewController *_pvc;
    AVPlayer *_player;
    AVPlayerItem *_observedItem;
    UIActivityIndicatorView *_spinner;
    UILabel *_status;
    UIImageView *_artwork;
    UITableView *_table;

    BOOL _audioOnly;
    BOOL _descriptionExpanded;
    BOOL _closed;
    CMTime _resumeTime;
    NSString *_qualityText;
    NSMutableArray *_remoteTargets;
    UIImage *_artworkImage;
}

- (instancetype)initWithVideo:(RWVideo *)video {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _video = video;
        _audioOnly = [RWSettings audioOnly];
        _resumeTime = kCMTimeInvalid;
        _remoteTargets = [NSMutableArray array];
        self.hidesBottomBarWhenPushed = YES;
        self.title = video.title;
    }
    return self;
}

- (void)dealloc {
    [self teardown];
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.automaticallyAdjustsScrollViewInsets = NO;

    _pvc = [AVPlayerViewController new];
    _pvc.view.backgroundColor = [UIColor blackColor];
    [self addChildViewController:_pvc];
    [self.view addSubview:_pvc.view];
    [_pvc didMoveToParentViewController:self];

    _artwork = [UIImageView new];
    _artwork.contentMode = UIViewContentModeScaleAspectFit;
    _artwork.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _artwork.hidden = YES;
    _artwork.frame = _pvc.contentOverlayView.bounds;
    [_pvc.contentOverlayView addSubview:_artwork];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.hidesWhenStopped = YES;
    [_pvc.view addSubview:_spinner];

    _status = [UILabel new];
    _status.textColor = [UIColor whiteColor];
    _status.font = [UIFont systemFontOfSize:14];
    _status.numberOfLines = 0;
    _status.textAlignment = NSTextAlignmentCenter;
    _status.hidden = YES;
    [_pvc.view addSubview:_status];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.estimatedRowHeight = 60;
    _table.rowHeight = UITableViewAutomaticDimension;
    [_table registerClass:[RWVideoCell class] forCellReuseIdentifier:@"video"];
    [self.view addSubview:_table];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(libraryChanged) name:RWLibraryDidChangeNotification object:nil];

    [RWLibrary addHistory:_video];
    [self loadInfo];

    __weak RWPlayerViewController *weakSelf = self;
    [[RWNetwork shared] loadImage:_video.thumbnailURL completion:^(UIImage *image) {
        RWPlayerViewController *s = weakSelf;
        if (!s || !image) return;
        s->_artworkImage = image;
        s->_artwork.image = image;
        [s updateNowPlaying];
    }];
}

- (BOOL)isLandscapePhone {
    CGSize size = self.view.bounds.size;
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone && size.width > size.height;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:[self isLandscapePhone] animated:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController) {
        [self.navigationController setNavigationBarHidden:NO animated:animated];
        [self teardown];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    BOOL landscape = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone && size.width > size.height;
    [self.navigationController setNavigationBarHidden:landscape animated:YES];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (BOOL)prefersStatusBarHidden { return [self isLandscapePhone]; }

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    if ([self isLandscapePhone]) {
        _pvc.view.frame = b;
        _table.hidden = YES;
    } else {
        CGFloat top = self.topLayoutGuide.length;
        CGFloat h = floor(b.size.width * 9.0 / 16.0);
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) h = MIN(h, floor(b.size.height * 0.55));
        _pvc.view.frame = CGRectMake(0, top, b.size.width, h);
        _table.hidden = NO;
        _table.frame = CGRectMake(0, top + h, b.size.width, b.size.height - top - h);
    }
    CGRect pb = _pvc.view.bounds;
    _spinner.center = CGPointMake(CGRectGetMidX(pb), CGRectGetMidY(pb));
    _status.frame = CGRectInset(pb, 24, 16);
}

#pragma mark - Loading

- (void)loadInfo {
    [_spinner startAnimating];
    [self showStatus:nil];
    __weak RWPlayerViewController *weakSelf = self;
    [RWAPI video:_video.videoId completion:^(NSDictionary *info, NSError *error) {
        RWPlayerViewController *s = weakSelf;
        if (!s || s->_closed) return;
        if (!info) {
            [s->_spinner stopAnimating];
            [s showStatus:[NSString stringWithFormat:@"Couldn't load this video.\n%@", error.localizedDescription ?: @""]];
            return;
        }
        s->_info = info;
        RWVideo *full = [RWVideo videoWithDictionary:info];
        if (full) { s->_video = full; s.title = full.title; }
        s->_channel = [RWChannel channelWithDictionary:info];
        NSString *desc = [info[@"description"] isKindOfClass:[NSString class]] ? info[@"description"] : nil;
        s->_description = [desc stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSMutableArray *related = [NSMutableArray array];
        for (NSDictionary *d in RWArray(info[@"recommendedVideos"])) {
            RWVideo *v = [RWVideo videoWithDictionary:d];
            if (v) [related addObject:v];
        }
        s->_related = related;
        [RWLibrary addHistory:s->_video];
        [s->_table reloadData];
        [s startPlayback];
    }];
}

- (void)showStatus:(NSString *)text {
    _status.text = text;
    _status.hidden = text.length == 0;
}

- (void)startPlayback {
    if (!_info || _closed) return;
    [self showStatus:nil];
    [_spinner startAnimating];
    if (_player) _resumeTime = _player.currentTime;

    if ([_info[@"liveNow"] boolValue]) {
        [_spinner stopAnimating];
        [self showStatus:@"Live streams aren't supported yet."];
        return;
    }
    NSArray *adaptive = RWArray(_info[@"adaptiveFormats"]);
    NSArray *muxed = RWArray(_info[@"formatStreams"]);
    NSDictionary *audio = RWPickAudio(adaptive);

    if (_audioOnly) {
        if (!audio) { [_spinner stopAnimating]; [self showStatus:@"No audio stream is available for this video."]; return; }
        _qualityText = @"Audio";
        [self playAsset:[[RWResourceLoader shared] assetWithURL:RWResolveURL(audio[@"url"])]];
        return;
    }

    NSInteger maxQuality = [RWSettings maxQuality];
    NSDictionary *combined = RWPickVideo(muxed, maxQuality);
    NSDictionary *video = RWPickVideo(adaptive, maxQuality);
    // A combined stream is simplest, but only use it if it's not worse than what adaptive offers.
    if (combined && (!video || !audio || RWHeight(combined) >= RWHeight(video))) {
        _qualityText = [NSString stringWithFormat:@"%ldp", (long)RWHeight(combined)];
        [self playAsset:[[RWResourceLoader shared] assetWithURL:RWResolveURL(combined[@"url"])]];
        return;
    }
    if (!video || !audio) {
        [_spinner stopAnimating];
        [self showStatus:@"This server didn't return an H.264 stream that iOS 10 can play."];
        return;
    }
    _qualityText = [NSString stringWithFormat:@"%ldp", (long)RWHeight(video)];
    [self playVideo:video audio:audio];
}

// YouTube serves picture and sound separately; stitch them into one composition.
- (void)playVideo:(NSDictionary *)videoFormat audio:(NSDictionary *)audioFormat {
    AVURLAsset *videoAsset = [[RWResourceLoader shared] assetWithURL:RWResolveURL(videoFormat[@"url"])];
    AVURLAsset *audioAsset = [[RWResourceLoader shared] assetWithURL:RWResolveURL(audioFormat[@"url"])];
    NSArray *keys = @[@"tracks", @"duration"];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    [videoAsset loadValuesAsynchronouslyForKeys:keys completionHandler:^{ dispatch_group_leave(group); }];
    dispatch_group_enter(group);
    [audioAsset loadValuesAsynchronouslyForKeys:keys completionHandler:^{ dispatch_group_leave(group); }];

    __weak RWPlayerViewController *weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        RWPlayerViewController *s = weakSelf;
        if (!s || s->_closed) return;
        NSError *error = nil;
        AVAsset *composition = [s compositionWithVideo:videoAsset audio:audioAsset error:&error];
        if (composition) {
            [s playAsset:composition];
        } else {
            s->_qualityText = @"Audio";
            [s playAsset:audioAsset];
            [s showStatus:[NSString stringWithFormat:@"Couldn't load the picture (%@). Playing sound only.", error.localizedDescription ?: @"unknown error"]];
        }
    });
}

- (AVAsset *)compositionWithVideo:(AVURLAsset *)videoAsset audio:(AVURLAsset *)audioAsset error:(NSError **)error {
    NSError *loadError = nil;
    if ([videoAsset statusOfValueForKey:@"tracks" error:&loadError] != AVKeyValueStatusLoaded ||
        [audioAsset statusOfValueForKey:@"tracks" error:&loadError] != AVKeyValueStatusLoaded) {
        if (error) *error = loadError;
        return nil;
    }
    AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audioTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!videoTrack || !audioTrack) {
        if (error) *error = [NSError errorWithDomain:@"Rewind" code:1 userInfo:@{NSLocalizedDescriptionKey: @"stream has no track"}];
        return nil;
    }
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *v = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *a = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTime videoDuration = RWUsableDuration(videoTrack, videoAsset, _video.lengthSeconds);
    CMTime audioDuration = RWUsableDuration(audioTrack, audioAsset, _video.lengthSeconds);
    if (![v insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoDuration) ofTrack:videoTrack atTime:kCMTimeZero error:error]) return nil;
    if (![a insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioDuration) ofTrack:audioTrack atTime:kCMTimeZero error:error]) return nil;
    v.preferredTransform = videoTrack.preferredTransform;
    return composition;
}

- (void)playAsset:(AVAsset *)asset {
    if (_closed) return;
    [self stopObservingItem];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:RWItemStatusContext];
    _observedItem = item;
    if (_player) [_player replaceCurrentItemWithPlayerItem:item];
    else _player = [AVPlayer playerWithPlayerItem:item];
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) _pvc.player = _player;
    _artwork.hidden = !_audioOnly;
    [_player play];
    [self setupRemoteCommands];
    [self updateNowPlaying];
    [_table reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)stopObservingItem {
    if (_observedItem) {
        [_observedItem removeObserver:self forKeyPath:@"status" context:RWItemStatusContext];
        _observedItem = nil;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != RWItemStatusContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerItem *item = object;
        if (item != self->_observedItem) return;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            [self->_spinner stopAnimating];
            if (CMTIME_IS_NUMERIC(self->_resumeTime) && CMTimeGetSeconds(self->_resumeTime) > 1) {
                [self->_player seekToTime:self->_resumeTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
            }
            self->_resumeTime = kCMTimeInvalid;
            [self updateNowPlaying];
        } else if (item.status == AVPlayerItemStatusFailed) {
            [self->_spinner stopAnimating];
            NSError *e = item.error;
            NSError *under = e.userInfo[NSUnderlyingErrorKey];
            NSString *detail = under.localizedDescription ?: e.localizedFailureReason ?: @"";
            [self showStatus:[NSString stringWithFormat:@"Playback failed.\n%@\n%@", e.localizedDescription ?: @"", detail]];
        }
    });
}

- (void)teardown {
    if (_closed) return;
    _closed = YES;
    [_player pause];
    [self stopObservingItem];
    _pvc.player = nil;
    _player = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
    for (NSArray *pair in _remoteTargets) [(MPRemoteCommand *)pair[0] removeTarget:pair[1]];
    [_remoteTargets removeAllObjects];
    (void)cc;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
}

#pragma mark - Background & lock screen

- (void)appDidEnterBackground { _pvc.player = nil; }   // detaching the layer keeps playback going
- (void)appWillEnterForeground { if (!_closed) _pvc.player = _player; }
- (void)libraryChanged { if (!_closed) [_table reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone]; }

- (void)addRemote:(MPRemoteCommand *)command handler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *e))handler {
    command.enabled = YES;
    id target = [command addTargetWithHandler:handler];
    [_remoteTargets addObject:@[command, target]];
}

- (void)setupRemoteCommands {
    if (_remoteTargets.count) return;
    MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
    __weak RWPlayerViewController *weakSelf = self;
    [self addRemote:cc.playCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        RWPlayerViewController *s = weakSelf;
        if (!s) return MPRemoteCommandHandlerStatusCommandFailed;
        [s->_player play]; [s updateNowPlaying];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemote:cc.pauseCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        RWPlayerViewController *s = weakSelf;
        if (!s) return MPRemoteCommandHandlerStatusCommandFailed;
        [s->_player pause]; [s updateNowPlaying];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemote:cc.togglePlayPauseCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        RWPlayerViewController *s = weakSelf;
        if (!s) return MPRemoteCommandHandlerStatusCommandFailed;
        if (s->_player.rate > 0) [s->_player pause]; else [s->_player play];
        [s updateNowPlaying];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    cc.skipForwardCommand.preferredIntervals = @[@15];
    cc.skipBackwardCommand.preferredIntervals = @[@15];
    [self addRemote:cc.skipForwardCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf skipBy:15]; return MPRemoteCommandHandlerStatusSuccess;
    }];
    [self addRemote:cc.skipBackwardCommand handler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf skipBy:-15]; return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)skipBy:(double)seconds {
    if (!_player) return;
    double t = MAX(0, CMTimeGetSeconds(_player.currentTime) + seconds);
    [_player seekToTime:CMTimeMakeWithSeconds(t, 600)];
    [self updateNowPlaying];
}

- (void)updateNowPlaying {
    if (_closed || !_player) return;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = _video.title ?: @"";
    info[MPMediaItemPropertyArtist] = _video.author ?: @"";
    if (_video.lengthSeconds > 0) info[MPMediaItemPropertyPlaybackDuration] = @(_video.lengthSeconds);
    double now = CMTimeGetSeconds(_player.currentTime);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(isnan(now) ? 0 : now);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(_player.rate);
    UIImage *art = _artworkImage;
    if (art) {
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:art.size requestHandler:^UIImage *(CGSize size) { return art; }];
    }
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

#pragma mark - Actions

- (void)toggleSave { [RWLibrary toggleSaved:_video]; }

- (void)toggleAudioOnly {
    _audioOnly = !_audioOnly;
    [self startPlayback];
}

- (void)chooseQuality:(UIView *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Maximum quality" message:@"Higher quality needs a faster connection and a newer device." preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *q in @[@240, @360, @480, @720, @1080]) {
        NSString *title = [NSString stringWithFormat:@"%@p%@", q, q.integerValue == [RWSettings maxQuality] ? @"  ✓" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [RWSettings setMaxQuality:q.integerValue];
            self->_audioOnly = NO;
            [self startPlayback];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)share:(UIView *)sender {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://youtu.be/%@", _video.videoId]];
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[_video.title ?: @"", url] applicationActivities:nil];
    vc.popoverPresentationController.sourceView = sender;
    vc.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)toggleSubscribe { if (_channel) [RWLibrary toggleSubscription:_channel]; }

#pragma mark - Table

typedef NS_ENUM(NSInteger, RWSection) { RWSectionInfo, RWSectionDescription, RWSectionRelated, RWSectionCount };

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return RWSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == RWSectionInfo) return _channel ? 3 : 2;
    if (section == RWSectionDescription) return _description.length ? 1 : 0;
    return _related.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == RWSectionRelated && _related.count) return @"Up next";
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == RWSectionRelated) return [RWVideoCell rowHeight];
    if (indexPath.section == RWSectionInfo && indexPath.row == 1) return 52;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == RWSectionInfo) return 0.01;
    if (section == RWSectionDescription && !_description.length) return 0.01;
    if (section == RWSectionRelated && !_related.count) return 0.01;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section { return section == RWSectionRelated ? 20 : 8; }

- (UIButton *)actionButton:(NSString *)title selected:(BOOL)selected action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:selected ? UIFontWeightSemibold : UIFontWeightRegular];
    b.tintColor = selected ? RWTintColor() : [UIColor darkGrayColor];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == RWSectionRelated) {
        RWVideoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"video" forIndexPath:indexPath];
        [cell configureWithVideo:_related[indexPath.row]];
        return cell;
    }
    if (indexPath.section == RWSectionDescription) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = _description;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.textLabel.textColor = [UIColor darkGrayColor];
        cell.textLabel.numberOfLines = _descriptionExpanded ? 0 : 3;
        return cell;
    }
    if (indexPath.row == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = _video.title;
        cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        cell.textLabel.numberOfLines = 0;
        NSMutableArray *meta = [NSMutableArray array];
        if (_video.viewText) [meta addObject:_video.viewText];
        if (_video.publishedText) [meta addObject:_video.publishedText];
        if (_qualityText) [meta addObject:_qualityText];
        cell.detailTextLabel.text = [meta componentsJoinedByString:@" · "];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.detailTextLabel.numberOfLines = 0;
        return cell;
    }
    if (indexPath.row == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        BOOL saved = [RWLibrary isSaved:_video.videoId];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self actionButton:saved ? @"★ Saved" : @"☆ Save" selected:saved action:@selector(toggleSave)],
            [self actionButton:_audioOnly ? @"♫ Audio only" : @"♫ Audio" selected:_audioOnly action:@selector(toggleAudioOnly)],
            [self actionButton:[NSString stringWithFormat:@"⚙︎ %ldp", (long)[RWSettings maxQuality]] selected:NO action:@selector(chooseQuality:)],
            [self actionButton:@"↗︎ Share" selected:NO action:@selector(share:)],
        ]];
        stack.distribution = UIStackViewDistributionFillEqually;
        stack.frame = cell.contentView.bounds;
        stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:stack];
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = _channel.name;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = _channel.subText;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    BOOL subscribed = [RWLibrary isSubscribed:_channel.ucid];
    UIButton *sub = [UIButton buttonWithType:UIButtonTypeSystem];
    [sub setTitle:subscribed ? @"SUBSCRIBED" : @"SUBSCRIBE" forState:UIControlStateNormal];
    sub.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    sub.tintColor = subscribed ? [UIColor grayColor] : RWTintColor();
    [sub addTarget:self action:@selector(toggleSubscribe) forControlEvents:UIControlEventTouchUpInside];
    [sub sizeToFit];
    cell.accessoryView = sub;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == RWSectionRelated) {
        RWPlayerViewController *next = [[RWPlayerViewController alloc] initWithVideo:_related[indexPath.row]];
        [_player pause];
        [self.navigationController pushViewController:next animated:YES];
    } else if (indexPath.section == RWSectionDescription) {
        _descriptionExpanded = !_descriptionExpanded;
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    } else if (indexPath.section == RWSectionInfo && indexPath.row == 2 && _channel) {
        [self.navigationController pushViewController:[[RWChannelViewController alloc] initWithChannel:_channel] animated:YES];
    }
}

@end
