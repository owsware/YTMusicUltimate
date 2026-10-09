#import "SongTransitionsSettingsController.h"
#import "../Transitions/YTMUSongTransitions.h"
#import "../Headers/Localization.h"
#include <math.h>

@implementation SongTransitionsSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = LOC(@"SONG_TRANSITIONS");
    self.view.tintColor = [UIColor colorWithRed:230.0 / 255 green:75.0 / 255 blue:75.0 / 255 alpha:1];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSettings)
                                                 name:YTMUTransitionsChangedNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)reloadSettings { [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [YTMUTransitionPreferences()[@"songTransitionMode"] integerValue] == YTMUTransitionCrossfade ? 3 : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return YTMUTransitionsAvailability(); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *preferences = YTMUTransitionPreferences();
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    BOOL supported = YTMUTransitionsCrossfadeSupported() && [preferences[@"YTMUltimateIsEnabled"] boolValue];
    if (indexPath.row == 0) {
        cell.textLabel.text = LOC(@"SONG_TRANSITIONS");
        UISwitch *control = [UISwitch new]; control.on = [preferences[@"songTransitionsEnabled"] boolValue];
        control.onTintColor = self.view.tintColor;
        control.enabled = supported && ([preferences[@"songTransitionMode"] integerValue] == YTMUTransitionCrossfade || YTMUTransitionsAutoMixSupported());
        [control addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = control;
    } else if (indexPath.row == 1) {
        UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[LOC(@"AUTOMIX"), LOC(@"CROSSFADE")]];
        control.selectedSegmentIndex = [preferences[@"songTransitionMode"] integerValue];
        control.enabled = supported;
        [control setEnabled:YTMUTransitionsAutoMixSupported() forSegmentAtIndex:0];
        [control addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
        control.accessibilityLabel = LOC(@"TRANSITION_STYLE");
        [cell.contentView addSubview:control]; control.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [control.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [control.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [control.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [control.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
        ]];
    } else {
        UILabel *label = [UILabel new]; label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.text = [NSString stringWithFormat:LOC(@"CROSSFADE_SECONDS"), [preferences[@"crossfadeDuration"] integerValue]];
        label.tag = 100;
        UISlider *slider = [UISlider new]; slider.minimumValue = 1; slider.maximumValue = 12;
        slider.value = [preferences[@"crossfadeDuration"] floatValue]; slider.enabled = supported;
        slider.accessibilityLabel = LOC(@"CROSSFADE_DURATION");
        slider.accessibilityValue = [NSString stringWithFormat:LOC(@"TRANSITION_SECONDS_VALUE"), (NSInteger)slider.value];
        [slider addTarget:self action:@selector(durationPreview:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(durationCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [cell.contentView addSubview:label]; [cell.contentView addSubview:slider];
        label.translatesAutoresizingMaskIntoConstraints = NO; slider.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [slider.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [slider.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [slider.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:6],
            [slider.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
        ]];
    }
    return cell;
}
- (void)enabledChanged:(UISwitch *)sender { YTMUSetTransitionPreference(@"songTransitionsEnabled", @(sender.on)); }
- (void)modeChanged:(UISegmentedControl *)sender { YTMUSetTransitionPreference(@"songTransitionMode", @(sender.selectedSegmentIndex)); }
- (void)durationPreview:(UISlider *)sender {
    sender.value = roundf(sender.value);
    UILabel *label = (UILabel *)[sender.superview viewWithTag:100];
    label.text = [NSString stringWithFormat:LOC(@"CROSSFADE_SECONDS"), (NSInteger)sender.value];
    sender.accessibilityValue = [NSString stringWithFormat:LOC(@"TRANSITION_SECONDS_VALUE"), (NSInteger)sender.value];
    if (!sender.tracking) [self durationCommitted:sender];
}
- (void)durationCommitted:(UISlider *)sender { YTMUSetTransitionPreference(@"crossfadeDuration", @((NSInteger)roundf(sender.value))); }
@end
