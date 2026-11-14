#import "RWUI.h"

typedef NS_ENUM(NSInteger, RWSettingsSection) {
    RWSettingsServer, RWSettingsPlayback, RWSettingsBrowse, RWSettingsData, RWSettingsAbout, RWSettingsCount
};

@implementation RWSettingsViewController {
    UITextField *_instanceField;
    UITextField *_regionField;
    UISwitch *_audioSwitch;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _instanceField = [self fieldWithPlaceholder:[RWSettings defaultInstance]];
    _instanceField.keyboardType = UIKeyboardTypeURL;
    _regionField = [self fieldWithPlaceholder:@"US"];
    _regionField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _regionField.textAlignment = NSTextAlignmentRight;
    _audioSwitch = [UISwitch new];
    _audioSwitch.onTintColor = RWTintColor();
    [_audioSwitch addTarget:self action:@selector(audioChanged) forControlEvents:UIControlEventValueChanged];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _instanceField.text = [RWSettings instance];
    _regionField.text = [RWSettings region];
    _audioSwitch.on = [RWSettings audioOnly];
    [self.tableView reloadData];
}

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder {
    UITextField *f = [UITextField new];
    f.placeholder = placeholder;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.returnKeyType = UIReturnKeyDone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.delegate = self;
    return f;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == _instanceField) {
        [RWSettings setInstance:textField.text];
        textField.text = [RWSettings instance];
    } else if (textField == _regionField) {
        [RWSettings setRegion:textField.text];
        textField.text = [RWSettings region];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RWLibraryDidChangeNotification object:nil];
}

- (void)audioChanged { [RWSettings setAudioOnly:_audioSwitch.on]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return RWSettingsCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case RWSettingsServer: return 3;
        case RWSettingsPlayback: return 2;
        case RWSettingsBrowse: return 1;
        case RWSettingsData: return 2;
        default: return 2;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Invidious server", @"Playback", @"Browse", @"Data", @"About"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == RWSettingsServer)
        return @"Rewind gets videos from an Invidious server, an open-source YouTube front end. Public servers come and go and many block apps; if videos stop loading, enter another server or host your own (docs.invidious.io).";
    if (section == RWSettingsBrowse) return @"Two-letter country code used for Trending.";
    if (section == RWSettingsData) return @"Subscriptions, saved videos and history are stored only on this device.";
    return nil;
}

- (void)place:(UIView *)field inCell:(UITableViewCell *)cell leftInset:(CGFloat)left {
    field.frame = CGRectMake(left, 0, cell.contentView.bounds.size.width - left - 16, cell.contentView.bounds.size.height);
    field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cell.contentView addSubview:field];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSInteger s = indexPath.section, r = indexPath.row;
    if (s == RWSettingsServer) {
        if (r == 0) { cell.selectionStyle = UITableViewCellSelectionStyleNone; [self place:_instanceField inCell:cell leftInset:16]; }
        else if (r == 1) { cell.textLabel.text = @"Test connection"; cell.textLabel.textColor = RWTintColor(); }
        else { cell.textLabel.text = @"Use default server"; cell.textLabel.textColor = RWTintColor(); }
    } else if (s == RWSettingsPlayback) {
        if (r == 0) {
            cell.textLabel.text = @"Maximum quality";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ldp", (long)[RWSettings maxQuality]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"Start in audio-only mode";
            cell.accessoryView = _audioSwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (s == RWSettingsBrowse) {
        cell.textLabel.text = @"Region";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [self place:_regionField inCell:cell leftInset:120];
    } else if (s == RWSettingsData) {
        cell.textLabel.text = r == 0 ? @"Clear watch history" : @"Clear image cache";
        cell.textLabel.textColor = r == 0 ? [UIColor redColor] : RWTintColor();
    } else {
        if (r == 0) {
            cell.textLabel.text = @"Version";
            cell.detailTextLabel.text = RW_VERSION;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"Source code";
            cell.detailTextLabel.text = @"GitHub";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.view endEditing:YES];
    NSInteger s = indexPath.section, r = indexPath.row;
    if (s == RWSettingsServer && r == 1) [self testConnection];
    else if (s == RWSettingsServer && r == 2) {
        [RWSettings setInstance:@""];
        _instanceField.text = [RWSettings instance];
        [[NSNotificationCenter defaultCenter] postNotificationName:RWLibraryDidChangeNotification object:nil];
    }
    else if (s == RWSettingsPlayback && r == 0) [self chooseQuality:[tableView cellForRowAtIndexPath:indexPath]];
    else if (s == RWSettingsData && r == 0) {
        [RWLibrary clearHistory];
        RWShowAlert(self, @"History cleared", nil);
    }
    else if (s == RWSettingsData && r == 1) {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        RWShowAlert(self, @"Cache cleared", nil);
    }
    else if (s == RWSettingsAbout && r == 1) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:RW_SOURCE_URL] options:@{} completionHandler:nil];
    }
}

- (void)testConnection {
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Testing…" message:[RWSettings instance] preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    [RWAPI search:@"music" type:@"video" page:1 completion:^(NSArray *items, NSString *next, NSError *error) {
        [wait dismissViewControllerAnimated:YES completion:^{
            if (items.count) RWShowAlert(self, @"It works", [NSString stringWithFormat:@"%@ answered with %lu results.", [RWSettings instance], (unsigned long)items.count]);
            else RWShowAlert(self, @"This server isn't working", error.localizedDescription ?: @"It returned no results.");
        }];
    }];
}

- (void)chooseQuality:(UIView *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Maximum quality" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *q in @[@240, @360, @480, @720, @1080]) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@p", q] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [RWSettings setMaxQuality:q.integerValue];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
