//
//  AppDelegate.m
//  Spotify Notifications
//

#import <ScriptingBridge/ScriptingBridge.h>
#import "Spotify.h"
#import "AppDelegate.h"
#import "SharedKeys.h"
#import "LaunchAtLogin.h"
#import <UserNotifications/UserNotifications.h>

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    
    //Register default preferences values
    [NSUserDefaults.standardUserDefaults registerDefaults:[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UserDefaults" ofType:@"plist"]]];

    if (@available(macOS 10.14, *)) {
        // Get permission for notifications
        [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError * _Nullable error) {
            if (error != nil) {
                NSLog(@"UNUserNotificationCenter error: %@", error);
            }
        }];

        // Get permission for Apple Events
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSAppleEventDescriptor *descriptor = [NSAppleEventDescriptor descriptorWithBundleIdentifier:SpotifyBundleID];
            OSStatus status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, typeWildCard, typeWildCard, YES);
            if (status != noErr) {
                NSLog(@"AEDeterminePermissionToAutomateTarget error: %d", status);
            }
        });
    }

    spotify =  [SBApplication applicationWithBundleIdentifier:SpotifyBundleID];

    [NSUserNotificationCenter.defaultUserNotificationCenter setDelegate:self];
    
    //Observe Spotify player state changes
    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(spotifyPlaybackStateChanged:)
                                                            name:SpotifyNotificationName
                                                          object:nil
                                              suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    [self setIcon];
    [self setupGlobalShortcutForNotifications];
    
    //User notification content images on 10.9+
    userNotificationContentImagePropertyAvailable = (NSAppKitVersionNumber >= NSAppKitVersionNumber10_9);
    if (!userNotificationContentImagePropertyAvailable) _albumArtToggle.enabled = NO;
    
    [LaunchAtLogin setAppIsLoginItem:[NSUserDefaults.standardUserDefaults boolForKey:kLaunchAtLoginKey]];
    
    //Check in case user opened application but Spotify already playing
    if (spotify.isRunning && spotify.playerState == SpotifyEPlSPlaying) {
        currentTrack = spotify.currentTrack;
        
        UNNotificationRequest *notification = [self userNotificationForCurrentTrack];
        [self deliverUserNotification:notification Force:YES];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setupGlobalShortcutForNotifications {

    static NSString *const kPreferenceGlobalShortcut = @"ShowCurrentTrack";
    _shortcutView.associatedUserDefaultsKey = kPreferenceGlobalShortcut;
    
    [MASShortcutBinder.sharedBinder
     bindShortcutWithDefaultsKey:kPreferenceGlobalShortcut
     toAction:^{

        UNNotificationRequest *notification = [self userNotificationForCurrentTrack];
         [self deliverUserNotification:notification Force:YES];
     }];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    // Allow opening preferences by re-opening the app
    // This allows accessing preferences even when the status item is hidden
    if (!flag) [self showPreferences:nil];
    return YES;
}

- (IBAction)openSpotify:(NSMenuItem*)sender {
    [spotify activate];
}

- (IBAction)showLastFM:(NSMenuItem*)sender {
    
    //Artist - we always need at least this
    NSMutableString *urlText = [NSMutableString new];
    [urlText appendFormat:@"http://last.fm/music/%@/", currentTrack.artist];
    
    if (sender.tag >= 1) [urlText appendFormat:@"%@/", currentTrack.album];
    if (sender.tag == 2) [urlText appendFormat:@"%@/", currentTrack.name];
    
    NSString *url = [urlText stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification {
    return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification {
    
    NSUserNotificationActivationType actionType = notification.activationType;
    
    if (actionType == NSUserNotificationActivationTypeContentsClicked) {
        [spotify activate];
        
    } else if (actionType == NSUserNotificationActivationTypeActionButtonClicked && spotify.playerState == SpotifyEPlSPlaying) {
        [spotify nextTrack];
    }
}

- (NSURL*)albumArtForTrack:(SpotifyTrack*)track {
    if (track.id) {
        //Looks hacky, but appears to work
        NSString *artworkUrl = [track.artworkUrl stringByReplacingOccurrencesOfString:@"http:" withString:@"https:"];
        NSData *artD = [NSData dataWithContentsOfURL:[NSURL URLWithString:artworkUrl]];
        if (artD == nil) {
            return nil;
        }

        NSURL *tempURL = [[NSFileManager defaultManager].temporaryDirectory URLByAppendingPathComponent:@"spotify-notifications.jpg"];
        if ([artD writeToURL:tempURL options:kNilOptions error:nil]) {
            return tempURL;
        }
    }
    
    return  nil;
}

- (UNNotificationRequest *)userNotificationForCurrentTrack {
    NSString *title = currentTrack.name;
    NSString *album = currentTrack.album;
    NSString *artist = currentTrack.artist;
    
    BOOL isAdvert = [currentTrack.spotifyUrl hasPrefix:@"spotify:ad"];

    UNMutableNotificationContent *notification = [[UNMutableNotificationContent alloc] init];
    notification.categoryIdentifier = @"nowplaying";
    notification.title = (title.length > 0 && !isAdvert)? title : @"No Song Playing";
    if (album.length > 0 && !isAdvert) notification.subtitle = album;
    if (artist.length > 0 && !isAdvert) notification.body = artist;
    
    BOOL includeAlbumArt = (userNotificationContentImagePropertyAvailable &&
                           [NSUserDefaults.standardUserDefaults boolForKey:kNotificationIncludeAlbumArtKey]
                            && !isAdvert);
    
    if (includeAlbumArt) {
        NSURL *artworkURL = [self albumArtForTrack:currentTrack];
        UNNotificationAttachment *attachment = [UNNotificationAttachment attachmentWithIdentifier:[NSUUID UUID].UUIDString URL:artworkURL options:@{} error:nil];
        if (attachment != nil) {
            notification.attachments = @[ attachment ];
        }
    }
    
    if (!isAdvert) {
        if ([NSUserDefaults.standardUserDefaults boolForKey:kNotificationSoundKey]) {
            if (@available(macOS 11, *)) {
                notification.sound = [UNNotificationSound soundNamed:@"Boop"];
            } else {
                notification.sound = [UNNotificationSound soundNamed:@"Pop"];
            }
        }
    }

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString content:notification trigger:nil];
    return request;
}

- (void)deliverUserNotification:(UNNotificationRequest *)notification Force:(BOOL)force {
    BOOL frontmost = [NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier isEqualToString:SpotifyBundleID];
    
    if (frontmost && [NSUserDefaults.standardUserDefaults boolForKey:kDisableWhenSpotifyHasFocusKey]) return;
    
    BOOL deliver = force;
    
    //If notifications enabled, and current track isn't the same as the previous track
    if ([NSUserDefaults.standardUserDefaults boolForKey:kNotificationsKey] &&
        (![previousTrack.id isEqualToString:currentTrack.id] || [NSUserDefaults.standardUserDefaults boolForKey:kPlayPauseNotificationsKey])) {
        
        //If only showing notification for current song, remove all other notifications..
        if ([NSUserDefaults.standardUserDefaults boolForKey:kShowOnlyCurrentSongKey])
            [NSUserNotificationCenter.defaultUserNotificationCenter removeAllDeliveredNotifications];
        
        //..then deliver this one
        deliver = YES;
    }
    
    if (spotify.isRunning && deliver) {
        [[UNUserNotificationCenter currentNotificationCenter] removeAllDeliveredNotifications];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:notification withCompletionHandler:nil];
    }
}

- (void)notPlaying {
    _openSpotifyMenuItem.title = @"Open Spotify (Not Playing)";
    
    [NSUserNotificationCenter.defaultUserNotificationCenter removeAllDeliveredNotifications];
}

- (void)spotifyPlaybackStateChanged:(NSNotification*)notification {
    
    if ([notification.userInfo[@"Player State"] isEqualToString:@"Stopped"]) {
        [self notPlaying];
        return; //To stop us from checking accessing spotify (spotify.playerState below)..
        //..and then causing it to re-open
    }
    
    if (spotify.playerState == SpotifyEPlSPlaying) {
        
        _openSpotifyMenuItem.title = @"Open Spotify (Playing)";

        if (!_openLastFMMenu.isEnabled && [currentTrack.artist isNotEqualTo:NULL])
            [_openLastFMMenu setEnabled:YES];
        
        
        if (![previousTrack.id isEqualToString:currentTrack.id]) {
            previousTrack = currentTrack;
            currentTrack = spotify.currentTrack;
        }

        UNNotificationRequest *userNotification = [self userNotificationForCurrentTrack];
        [self deliverUserNotification:userNotification Force:NO];
        
        
    } else if ([NSUserDefaults.standardUserDefaults boolForKey:kShowOnlyCurrentSongKey]
               && (spotify.playerState == SpotifyEPlSPaused || spotify.playerState == SpotifyEPlSStopped)) {
        [self notPlaying];
    }

}

#pragma mark - Preferences

- (IBAction)showPreferences:(NSMenuItem*)sender {
    [_prefsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)setIcon {
    
    NSInteger iconSelection = [NSUserDefaults.standardUserDefaults integerForKey:kIconSelectionKey];
    
    if (iconSelection == 2 && _statusBar) {
        _statusBar = nil;
        
    } else if (iconSelection == 0 || iconSelection == 1) {
        
        NSString *imageName = (iconSelection == 0)? @"status_bar_colour.tiff" : @"status_bar_black.tiff";
        if (!_statusBar) {
            _statusBar = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
            _statusBar.menu = _statusMenu;
            _statusBar.highlightMode = YES;
        }
        
        if (![_statusBar.image.name isEqualToString:imageName]) _statusBar.image = [NSImage imageNamed:imageName];
        
        _statusBar.image.template = (iconSelection == 1);
    }
}

- (IBAction)toggleIcons:(id)sender {
    [self setIcon];
}

- (IBAction)toggleStartup:(NSButton *)sender {
    
    BOOL launchAtLogin = sender.state;
    [NSUserDefaults.standardUserDefaults setBool:launchAtLogin forKey:kLaunchAtLoginKey];
    [LaunchAtLogin setAppIsLoginItem:launchAtLogin];
}

#pragma mark - Preferences Info Buttons

- (IBAction)showHome:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"http://spotify-notifications.citruspi.io"]];
}

- (IBAction)showSource:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/citruspi/Spotify-Notifications"]];
}

- (IBAction)showContributors:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/citruspi/Spotify-Notifications/graphs/contributors"]];
    
}

@end
