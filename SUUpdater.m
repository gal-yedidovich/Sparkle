//
//  SUUpdater.m
//  Sparkle
//
//  Created by Andy Matuschak on 1/4/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#import "Sparkle.h"
#import "SUUpdater.h"

@interface SUUpdater (Private)
- (void)beginUpdateCycle;
- (NSArray *)feedParameters;
- (BOOL)automaticallyUpdates;
@end

@implementation SUUpdater

#pragma mark Initialization

static SUUpdater *sharedUpdater = nil;

// SUUpdater's a singleton now! And I'm enforcing it!
// This will probably break the world if you try to write a Sparkle-enabled plugin for a Sparkle-enabled app.
+ (SUUpdater *)sharedUpdater
{
	if (sharedUpdater == nil)
		sharedUpdater = [[[self class] alloc] init];
	return sharedUpdater;
}

- (id)init
{
	self = [super init];
	if (sharedUpdater)
	{
		[self release];
		self = sharedUpdater;
	}
	else if (self != nil)
	{
		sharedUpdater = self;
		[self setHostBundle:[NSBundle mainBundle]];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidFinishLaunching:) name:NSApplicationDidFinishLaunchingNotification object:NSApp];
	}
	return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
	// If the user has been asked about automatic checks and said no, get out of here.
	if ([[SUUserDefaults standardUserDefaults] objectForKey:SUEnableAutomaticChecksKey] &&
		[[SUUserDefaults standardUserDefaults] boolForKey:SUEnableAutomaticChecksKey] == NO) { return; }
	
	// Has he been asked already?
	if ([[SUUserDefaults standardUserDefaults] objectForKey:SUEnableAutomaticChecksKey] == nil)
	{
		if ([[SUUserDefaults standardUserDefaults] objectForKey:SUEnableAutomaticChecksKeyOld])
			[[SUUserDefaults standardUserDefaults] setBool:[[SUUserDefaults standardUserDefaults] boolForKey:SUEnableAutomaticChecksKeyOld] forKey:SUEnableAutomaticChecksKey];
		// Now, we don't want to ask the user for permission to do a weird thing on the first launch.
		// We wait until the second launch.
		else if ([[SUUserDefaults standardUserDefaults] boolForKey:SUHasLaunchedBeforeKey] == NO)
			[[SUUserDefaults standardUserDefaults] setBool:YES forKey:SUHasLaunchedBeforeKey];
		else
			[SUUpdatePermissionPrompt promptWithHostBundle:hostBundle delegate:self];
	}
	
	if ([[SUUserDefaults standardUserDefaults] boolForKey:SUEnableAutomaticChecksKey] == YES)
		[self beginUpdateCycle];
}

- (void)updatePermissionPromptFinishedWithResult:(SUPermissionPromptResult)result
{
	BOOL automaticallyCheck = (result == SUAutomaticallyCheck);
	[[SUUserDefaults standardUserDefaults] setBool:automaticallyCheck forKey:SUEnableAutomaticChecksKey];
	if ([self automaticallyUpdates])
		[self beginUpdateCycle];
}

- (void)beginUpdateCycle
{
	// Find the stored check interval. User defaults override Info.plist.
	if ([[SUUserDefaults standardUserDefaults] objectForKey:SUScheduledCheckIntervalKey])
		checkInterval = [[[SUUserDefaults standardUserDefaults] objectForKey:SUScheduledCheckIntervalKey] longValue];
	else if ([hostBundle objectForInfoDictionaryKey:SUScheduledCheckIntervalKey])
		checkInterval = [[hostBundle objectForInfoDictionaryKey:SUScheduledCheckIntervalKey] longValue];
	
	if (checkInterval < SU_MIN_CHECK_INTERVAL) // This can also mean one that isn't set.
		checkInterval = SU_DEFAULT_CHECK_INTERVAL;
	
	// How long has it been since last we checked for an update?
	NSDate *lastCheckDate = [[SUUserDefaults standardUserDefaults] objectForKey:SULastCheckTimeKey];
	if (!lastCheckDate) { lastCheckDate = [NSDate distantPast]; }
	NSTimeInterval intervalSinceCheck = [[NSDate date] timeIntervalSinceDate:lastCheckDate];
	
	// Now we want to figure out how long until we check again.
	NSTimeInterval delayUntilCheck;
	if (intervalSinceCheck < checkInterval)
		delayUntilCheck = (checkInterval - intervalSinceCheck); // It hasn't been long enough.
	else
		delayUntilCheck = 0; // We're overdue! Run one now.
	
	checkTimer = [NSTimer scheduledTimerWithTimeInterval:delayUntilCheck target:self selector:@selector(checkForUpdatesInBackground) userInfo:nil repeats:NO];
}

- (void)checkForUpdatesInBackground
{
	[self checkForUpdatesWithDriver:[[[([self automaticallyUpdates] ? [SUAutomaticUpdateDriver class] : [SUScheduledUpdateDriver class]) alloc] init] autorelease]];
}

- (IBAction)checkForUpdates:sender
{
	[self checkForUpdatesWithDriver:[[[SUUserInitiatedUpdateDriver alloc] init] autorelease]];
}

- (void)checkForUpdatesWithDriver:(SUUpdateDriver *)d
{
	if ([self updateInProgress]) { return; }
	if (checkTimer) { [checkTimer invalidate]; checkTimer = nil; }
	
	// A value in the user defaults overrides one in the Info.plist (so preferences panels can be created wherein users choose between beta / release feeds).
	NSString *appcastString = [[SUUserDefaults standardUserDefaults] objectForKey:SUFeedURLKey];
	if (!appcastString)
		appcastString = [hostBundle objectForInfoDictionaryKey:SUFeedURLKey];
	if (!appcastString)
		[NSException raise:@"SUNoFeedURL" format:@"You must specify the URL of the appcast as the SUFeedURLKey in either the Info.plist or the user defaults!"];
	NSCharacterSet* quoteSet = [NSCharacterSet characterSetWithCharactersInString: @"\"\'"]; // Some feed publishers add quotes; strip 'em.
	NSURL *feedURL = [[NSURL URLWithString:[appcastString stringByTrimmingCharactersInSet:quoteSet]] URLWithParameters:[self feedParameters]];
	
	driver = [d retain];
	if ([driver delegate] == nil) { [driver setDelegate:delegate]; }
	[driver addObserver:self forKeyPath:@"finished" options:0 context:NULL];
	[driver checkForUpdatesAtURL:feedURL hostBundle:hostBundle];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (object != driver) { return; }
	[driver removeObserver:self forKeyPath:@"finished"];
	[driver release]; driver = nil;
	[NSTimer scheduledTimerWithTimeInterval:checkInterval target:self selector:@selector(checkForUpdatesInBackground) userInfo:nil repeats:NO];
}

- (BOOL)automaticallyUpdates
{
	// If the SUAllowsAutomaticUpdatesKey exists and is set to NO, return NO.
	if ([hostBundle objectForInfoDictionaryKey:SUAllowsAutomaticUpdatesKey] &&
		[[hostBundle objectForInfoDictionaryKey:SUAllowsAutomaticUpdatesKey] boolValue] == NO)
		return NO;
	
	// If we're not using DSA signatures, we aren't going to trust any updates automatically.
	if ([[hostBundle objectForInfoDictionaryKey:SUExpectsDSASignatureKey] boolValue] != YES)
		return NO;
	
	// If there's no setting, or it's set to no, we're not automatically updating.
	if ([[SUUserDefaults standardUserDefaults] boolForKey:SUAutomaticallyUpdateKey] != YES)
		return NO;
	
	return YES; // Otherwise, we're good to go.
}

- (NSArray *)feedParameters
{
	BOOL sendingSystemProfile = ([[SUUserDefaults standardUserDefaults] boolForKey:SUSendProfileInfoKey] == YES);
	NSArray *parameters = [NSArray array];
	if ([delegate respondsToSelector:@selector(feedParametersForUpdater:sendingSystemProfile:)])
		parameters = [parameters arrayByAddingObjectsFromArray:[delegate feedParametersForUpdater:self sendingSystemProfile:sendingSystemProfile]];
	if (sendingSystemProfile)
		parameters = [parameters arrayByAddingObjectsFromArray:[hostBundle systemProfile]];
	return parameters;
}

- (void)dealloc
{
	[hostBundle release];
	[delegate release];
	if (checkTimer) { [checkTimer invalidate]; }
	[super dealloc];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	if ([item action] == @selector(checkForUpdates:))
		return ![self updateInProgress];
	return YES;
}

- (void)setDelegate:aDelegate
{
	[delegate release];
	delegate = [aDelegate retain];
}

- (void)setHostBundle:(NSBundle *)hb
{
	[hostBundle release];
	hostBundle = [hb retain];
	[[SUUserDefaults standardUserDefaults] setIdentifier:[hostBundle bundleIdentifier]];
}

- (BOOL)updateInProgress
{
	return driver && ([driver finished] == NO);
}

@end
