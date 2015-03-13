//
//  Created by Cédric Luthi on 25.02.15.
//  Copyright (c) 2015 RTS. All rights reserved.
//

#import "RTSMediaPlayerController.h"
#import "RTSMediaPlayerView.h"

#import <TransitionKit/TransitionKit.h>
#import <libextobjc/EXTScope.h>

NSString * const RTSMediaPlayerPlaybackDidFinishNotification = @"RTSMediaPlayerPlaybackDidFinish";
NSString * const RTSMediaPlayerPlaybackStateDidChangeNotification = @"RTSMediaPlayerPlaybackStateDidChange";
NSString * const RTSMediaPlayerNowPlayingMediaDidChangeNotification = @"RTSMediaPlayerNowPlayingMediaDidChange";
NSString * const RTSMediaPlayerReadyToPlayNotification = @"RTSMediaPlayerReadyToPlay";


NSString * const RTSMediaPlayerPlaybackDidFinishReasonUserInfoKey = @"Reason";
NSString * const RTSMediaPlayerPlaybackDidFinishErrorUserInfoKey = @"Error";

@interface RTSMediaPlayerControllerURLDataSource : NSObject <RTSMediaPlayerControllerDataSource>
@end

@implementation RTSMediaPlayerControllerURLDataSource

- (void) mediaPlayerController:(RTSMediaPlayerController *)mediaPlayerController contentURLForIdentifier:(NSString *)identifier completionHandler:(void (^)(NSURL *contentURL, NSError *error))completionHandler
{
	completionHandler([NSURL URLWithString:identifier], nil);
}

@end

@interface RTSMediaPlayerController ()

@property (readonly) TKStateMachine *loadStateMachine;
@property (readwrite) TKState *noneState;
@property (readwrite) TKState *contentURLLoadedState;
@property (readwrite) TKEvent *loadContentURLEvent;
@property (readwrite) TKEvent *loadAssetEvent;
@property (readwrite) TKEvent *resetLoadStateMachineEvent;

@property (readwrite) RTSMediaPlaybackState playbackState;
@property (readwrite) AVPlayer *player;

@property RTSMediaPlayerControllerURLDataSource *contentURLDataSource;

@end

@implementation RTSMediaPlayerController

- (instancetype) initWithContentURL:(NSURL *)contentURL
{
	_contentURLDataSource = [RTSMediaPlayerControllerURLDataSource new];
	return [self initWithContentIdentifier:contentURL.absoluteString dataSource:_contentURLDataSource];
}

- (instancetype) initWithContentIdentifier:(NSString *)identifier dataSource:(id<RTSMediaPlayerControllerDataSource>)dataSource
{
	if (!(self = [super init]))
		return nil;
	
	_identifier = identifier;
	_dataSource = dataSource;
	
	return self;
}

- (void) dealloc
{
	[self stop];
	self.player = nil;
}

@synthesize loadStateMachine = _loadStateMachine;

static const NSString *ResultKey = @"Result";
static const NSString *ShouldPlayKey = @"ShouldPlay";

static NSDictionary * TransitionUserInfo(TKTransition *transition, id<NSCopying> key, id value)
{
	NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:transition.userInfo];
	userInfo[key] = value;
	return [userInfo copy];
}

- (TKStateMachine *) loadStateMachine
{
	if (_loadStateMachine)
		return _loadStateMachine;
	
	TKStateMachine *loadStateMachine = [TKStateMachine new];
	TKState *none = [TKState stateWithName:@"None"];
	TKState *loadingContentURL = [TKState stateWithName:@"Loading Content URL"];
	TKState *contentURLLoaded = [TKState stateWithName:@"Content URL Loaded"];
	TKState *loadingAsset = [TKState stateWithName:@"Loading Asset"];
	TKState *assetLoaded = [TKState stateWithName:@"Asset Loaded"];
	[loadStateMachine addStates:@[ none, loadingContentURL, contentURLLoaded, loadingAsset, assetLoaded ]];
	loadStateMachine.initialState = none;
	
	TKEvent *loadContentURL = [TKEvent eventWithName:@"Load Content URL" transitioningFromStates:@[ none ] toState:loadingContentURL];
	TKEvent *loadContentURLFailure = [TKEvent eventWithName:@"Load Content URL Failure" transitioningFromStates:@[ loadingContentURL ] toState:none];
	TKEvent *loadContentURLSuccess = [TKEvent eventWithName:@"Load Content URL Success" transitioningFromStates:@[ loadingContentURL ] toState:contentURLLoaded];
	TKEvent *loadAsset = [TKEvent eventWithName:@"Load Asset" transitioningFromStates:@[ contentURLLoaded ] toState:loadingAsset];
	TKEvent *loadAssetFailure = [TKEvent eventWithName:@"Load Asset Failure" transitioningFromStates:@[ loadingAsset ] toState:contentURLLoaded];
	TKEvent *loadAssetSuccess = [TKEvent eventWithName:@"Load Asset Success" transitioningFromStates:@[ loadingAsset ] toState:assetLoaded];
	TKEvent *resetLoadStateMachine = [TKEvent eventWithName:@"Reset" transitioningFromStates:@[ loadingContentURL, contentURLLoaded, loadingAsset, assetLoaded ] toState:none];
	
	[loadStateMachine addEvents:@[ loadContentURL, loadContentURLFailure, loadContentURLSuccess, loadAsset, loadAssetFailure, loadAssetSuccess ]];
	
	@weakify(self)
	
	void (^postError)(TKState *, TKTransition *) = ^(TKState *state, TKTransition *transition) {
		@strongify(self)
		id result = transition.userInfo[ResultKey];
		if ([result isKindOfClass:[NSError class]])
			[self postPlaybackDidFinishErrorNotification:result];
	};
	
	[loadingContentURL setDidEnterStateBlock:^(TKState *state, TKTransition *transition) {
		@strongify(self)
		if (!self.dataSource)
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"RTSMediaPlayerController dataSource can not be nil." userInfo:nil];
		
		self.playbackState = RTSMediaPlaybackStatePendingPlay;
		
		[self.dataSource mediaPlayerController:self contentURLForIdentifier:self.identifier completionHandler:^(NSURL *contentURL, NSError *error) {
			if (contentURL)
			{
				[self.loadStateMachine fireEvent:loadContentURLSuccess userInfo:TransitionUserInfo(transition, ResultKey, contentURL) error:NULL];
			}
			else if (error)
			{
				[self.loadStateMachine fireEvent:loadContentURLFailure userInfo:TransitionUserInfo(transition, ResultKey, error) error:NULL];
			}
			else
			{
				@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"The RTSMediaPlayerControllerDataSource implementation returned a nil contentURL and a nil error." userInfo:nil];
			}
		}];
	}];
	
	[loadingContentURL setDidExitStateBlock:postError];
	
	[contentURLLoaded setDidEnterStateBlock:^(TKState *state, TKTransition *transition) {
		@strongify(self)
		if (transition.sourceState == loadingContentURL)
			[self.loadStateMachine fireEvent:loadAsset userInfo:transition.userInfo error:NULL];
	}];
	
	[loadingAsset setDidEnterStateBlock:^(TKState *state, TKTransition *transition) {
		@strongify(self)
		NSURL *contentURL = transition.userInfo[ResultKey];
		AVURLAsset *asset = [AVURLAsset URLAssetWithURL:contentURL options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @(YES) }];
		static NSString *assetStatusKey = @"duration";
		[asset loadValuesAsynchronouslyForKeys:@[ assetStatusKey ] completionHandler:^{
			dispatch_async(dispatch_get_main_queue(), ^{
				NSError *valueStatusError = nil;
				AVKeyValueStatus status = [asset statusOfValueForKey:assetStatusKey error:&valueStatusError];
				if (status == AVKeyValueStatusLoaded)
				{
					[self.loadStateMachine fireEvent:loadAssetSuccess userInfo:TransitionUserInfo(transition, ResultKey, asset) error:NULL];
				}
				else
				{
					NSError *error = valueStatusError ?: [NSError errorWithDomain:@"XXX" code:0 userInfo:nil];
					[self.loadStateMachine fireEvent:loadAssetFailure userInfo:TransitionUserInfo(transition, ResultKey, error) error:NULL];
				}
			});
		}];
	}];
	
	[loadingAsset setDidExitStateBlock:postError];
	
	[assetLoaded setWillEnterStateBlock:^(TKState *state, TKTransition *transition) {
		@strongify(self)
		AVAsset *asset = transition.userInfo[ResultKey];
		self.player = [AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
		[(RTSMediaPlayerView *)self.view setPlayer:self.player];
		[[NSNotificationCenter defaultCenter] postNotificationName:RTSMediaPlayerReadyToPlayNotification object:self];
		if ([transition.userInfo[ShouldPlayKey] boolValue])
			[self.player play];
	}];
	
	[assetLoaded setWillExitStateBlock:^(TKState *state, TKTransition *transition) {
		@strongify(self)
		RTSMediaPlaybackState playbackState = self.playbackState;
		if (playbackState == RTSMediaPlaybackStatePlaying || playbackState == RTSMediaPlaybackStatePaused)
			[self postPlaybackDidFinishNotification:RTSMediaFinishReasonUserExited error:nil];
		
		self.playbackState = RTSMediaPlaybackStateEnded;
		
		[(RTSMediaPlayerView *)self.view setPlayer:nil];
		self.player = nil;
	}];
	
	[loadStateMachine activate];
	
	self.noneState = none;
	self.contentURLLoadedState = contentURLLoaded;
	self.loadContentURLEvent = loadContentURL;
	self.loadAssetEvent = loadAsset;
	self.resetLoadStateMachineEvent = resetLoadStateMachine;
	
	_loadStateMachine = loadStateMachine;
	
	return _loadStateMachine;
}

- (void) postPlaybackDidFinishErrorNotification:(NSError *)error
{
	[self postPlaybackDidFinishNotification:RTSMediaFinishReasonPlaybackError error:error];
}

- (void) postPlaybackDidFinishNotification:(RTSMediaFinishReason)reason error:(NSError *)error
{
	NSMutableDictionary *userInfo = [NSMutableDictionary new];
	[userInfo setObject:@(reason) forKey:RTSMediaPlayerPlaybackDidFinishReasonUserInfoKey];
	
	if (error)
		[userInfo setObject:error forKey:RTSMediaPlayerPlaybackDidFinishErrorUserInfoKey];
	
	[[NSNotificationCenter defaultCenter] postNotificationName:RTSMediaPlayerPlaybackDidFinishNotification object:self userInfo:userInfo];
}

- (void) play
{
	if (self.player)
	{
		[self.player play];
	}
	else
	{
		[self loadAndPlay:YES];
	}
}

- (void) prepareToPlay
{
	[self loadAndPlay:NO];
}

- (void) loadAndPlay:(BOOL)shouldPlay
{
	NSDictionary *userInfo = @{ ShouldPlayKey: @(shouldPlay) };
	if ([self.loadStateMachine.currentState isEqual:self.noneState])
		[self.loadStateMachine fireEvent:self.loadContentURLEvent userInfo:userInfo error:NULL];
	else if ([self.loadStateMachine.currentState isEqual:self.contentURLLoadedState])
		[self.loadStateMachine fireEvent:self.loadAssetEvent userInfo:userInfo error:NULL];
}

- (void) playIdentifier:(NSString *)identifier
{
	if (![self.identifier isEqualToString:identifier])
	{
		self.identifier = identifier;
		[self.loadStateMachine fireEvent:self.resetLoadStateMachineEvent userInfo:nil error:NULL];
	}
	
	[self loadAndPlay:YES];
}

- (void) pause
{
	[self.player pause];
}

- (void) stop
{
	[self.loadStateMachine fireEvent:self.resetLoadStateMachineEvent userInfo:nil error:nil];
}

- (void) seekToTime:(NSTimeInterval)time
{
	[self.player seekToTime:CMTimeMakeWithSeconds(time, 1000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:NULL];
}

@synthesize playbackState = _playbackState;

- (RTSMediaPlaybackState) playbackState
{
	@synchronized(self)
	{
		return _playbackState;
	}
}

- (void) setPlaybackState:(RTSMediaPlaybackState)playbackState
{
	@synchronized(self)
	{
		if (_playbackState == playbackState)
			return;
		
		_playbackState = playbackState;
		
		[[NSNotificationCenter defaultCenter] postNotificationName:RTSMediaPlayerPlaybackStateDidChangeNotification object:self userInfo:nil];
	}
}

#pragma mark - AVPlayer

static const void * const AVPlayerRateContext = &AVPlayerRateContext;

@synthesize player = _player;

- (AVPlayer *) player
{
	@synchronized(self)
	{
		return _player;
	}
}

- (void) setPlayer:(AVPlayer *)player
{
	@synchronized(self)
	{
		[_player removeObserver:self forKeyPath:@"rate" context:(void *)AVPlayerRateContext];
		
		_player = player;
		
		[_player addObserver:self forKeyPath:@"rate" options:0 context:(void *)AVPlayerRateContext];
	}
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context == AVPlayerRateContext)
	{
		BOOL paused = self.player.rate == 0.f;
		RTSMediaPlaybackState newState = paused ? RTSMediaPlaybackStatePaused : RTSMediaPlaybackStatePlaying;
		if (self.playbackState != newState)
			self.playbackState = newState;
	}
	else
	{
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

- (void) attachPlayerToView:(UIView *)containerView
{
	if (self.view.superview)
		[self.view removeFromSuperview];
	
	self.view.frame = CGRectMake(0, 0, CGRectGetWidth(containerView.bounds), CGRectGetHeight(containerView.bounds));
	[containerView insertSubview:self.view atIndex:0];
}

@synthesize view = _view;

- (UIView *) view
{
	if (!_view)
	{
		_view = [RTSMediaPlayerView new];
		_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[_view addGestureRecognizer:self.tapGestureRecognizer];
	}
	return _view;
}

#pragma mark - Overlays

@synthesize tapGestureRecognizer = _tapGestureRecognizer;

- (UITapGestureRecognizer *) tapGestureRecognizer
{
	if (!_tapGestureRecognizer)
	{
		_tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(viewWasTaped:)];
	}
	return _tapGestureRecognizer;
}

- (void) viewWasTaped:(id)sender
{
	[self setOverlaysHidden:![[UIApplication sharedApplication] isStatusBarHidden]];
}

- (void) showOverlays
{
	[self setOverlaysHidden:NO];
}

- (void) hideOverlays
{
	[self setOverlaysHidden:YES];
}

- (void) setOverlaysHidden:(BOOL)hidden
{
	for (UIView<RTSOverlayViewProtocol> *view in self.overlayViews)
	{
		if ([view respondsToSelector:@selector(mediaPlayerController:overlayHidden:)])
			[view mediaPlayerController:self overlayHidden:hidden];
		else
			[view setHidden:hidden];
	}
	
	//TODO : fix for inline player
	[[UIApplication sharedApplication] setStatusBarHidden:hidden withAnimation:UIStatusBarAnimationFade];
}


@end
