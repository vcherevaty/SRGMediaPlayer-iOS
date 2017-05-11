//
//  Copyright (c) SRG. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "RTSTimeSlider.h"

#import "NSBundle+RTSMediaPlayer.h"
#import "RTSMediaPlayerLogger+Private.h"
#import "UIBezierPath+RTSMediaPlayerUtils.h"

#import <SRGMediaPlayer/RTSMediaPlayerController.h>
#import <libextobjc/EXTScope.h>

#define SLIDER_VERTICAL_CENTER self.frame.size.height/2

static NSString *RTSTimeSliderFormatter(NSTimeInterval seconds)
{
	if (isnan(seconds))
		return @"NaN";
	else if (isinf(seconds))
		return seconds > 0 ? @"∞" : @"-∞";
	
	div_t qr = div((int)round(ABS(seconds)), 60);
	int second = qr.rem;
	qr = div(qr.quot, 60);
	int minute = qr.rem;
	int hour = qr.quot;
	
	BOOL negative = seconds < 0;
	if (hour > 0)
		return [NSString stringWithFormat:@"%@%02d:%02d:%02d", negative ? @"-" : @"", hour, minute, second];
	else
		return [NSString stringWithFormat:@"%@%02d:%02d", negative ? @"-" : @"", minute, second];
}

@interface RTSTimeSlider ()

@property (weak) id periodicTimeObserver;
@property (nonatomic, strong) UIColor *overriddenThumbTintColor;
@property (nonatomic, strong) UIColor *overriddenMaximumTrackTintColor;
@property (nonatomic, strong) UIColor *overriddenMinimumTrackTintColor;

@end

@implementation RTSTimeSlider

#pragma mark - initialization

- (instancetype) initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		[self setup_RTSTimeSlider];
	}
	return self;
}

- (instancetype) initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self) {
		[self setup_RTSTimeSlider];
	}
	return self;
}

- (void) setup_RTSTimeSlider
{
	self.borderColor = [UIColor blackColor];
	
	self.minimumValue = 0.;			// Always 0
	self.maximumValue = 0.;
	self.value = 0.;
	
	UIImage *triangle = [self emptyImage];
	UIImage *image = [triangle resizableImageWithCapInsets:UIEdgeInsetsMake(1, 1, 1, 1)];
	
	[self setMinimumTrackImage:image forState:UIControlStateNormal];
	[self setMaximumTrackImage:image forState:UIControlStateNormal];
	
	[self setThumbImage:[self thumbImage] forState:UIControlStateNormal];
	[self setThumbImage:[self thumbImage] forState:UIControlStateHighlighted];
	
	self.seekingDuringTracking = YES;
	self.knobLivePosition = RTSTimeSliderLiveKnobPositionLeft;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setters and getters

- (BOOL) isDraggable
{
	// A slider knob can be dragged iff it corresponds to a valid range
	return self.minimumValue != self.maximumValue;
}

// Override color properties since the default superclass behavior is to remove corresponding images, which we here
// already set in -setup_RTSTimeSlider and want to preserve

- (UIColor *) thumbTintColor
{
	return self.overriddenThumbTintColor ?: [UIColor whiteColor];
}

- (void) setThumbTintColor:(UIColor *)thumbTintColor
{
	self.overriddenThumbTintColor = thumbTintColor;
}

- (UIColor *) minimumTrackTintColor
{
	return self.overriddenMinimumTrackTintColor ?: [UIColor whiteColor];
}

- (void) setMinimumTrackTintColor:(UIColor *)minimumTrackTintColor
{
	self.overriddenMinimumTrackTintColor = minimumTrackTintColor;
}

- (UIColor *) maximumTrackTintColor
{
	return self.overriddenMaximumTrackTintColor ?: [UIColor blackColor];
}

- (void) setMaximumTrackTintColor:(UIColor *)maximumTrackTintColor
{
	self.overriddenMaximumTrackTintColor = maximumTrackTintColor;
}


#pragma mark - Time display

- (CMTime) time
{
	CMTimeRange timeRange = self.mediaPlayerController.timeRange;
	if (CMTIMERANGE_IS_EMPTY(timeRange)) {
		return kCMTimeZero;
	}
	
	CMTime relativeTime = CMTimeMakeWithSeconds(self.value, NSEC_PER_SEC);
	return CMTimeAdd(timeRange.start, relativeTime);
}

- (BOOL) isLive
{
	// Live and timeshift feeds in live conditions. This happens when either the following condition
	// is met:
	//  - We have a pure live feed, which is characterized by an empty range
	//  - We have a timeshift feed, which is characterized by an indefinite player item duration, and whose slider knob is
	//    dragged close to now. We consider a timeshift 'close to now' when the slider is at the end, up to a tolerance
	return self.mediaPlayerController.streamType == RTSMediaStreamTypeLive
		|| (self.mediaPlayerController.streamType == RTSMediaStreamTypeDVR && (self.maximumValue - self.value < self.mediaPlayerController.liveTolerance));
}

- (void) updateTimeRangeLabels
{
	AVPlayerItem *playerItem = self.mediaPlayerController.playerItem;
	if (! playerItem || self.mediaPlayerController.playbackState == RTSMediaPlaybackStateIdle || self.mediaPlayerController.playbackState == RTSMediaPlaybackStateEnded
			|| playerItem.status != AVPlayerItemStatusReadyToPlay) {

//FIX->
//		self.valueLabel.text = @"--:--";
//		self.timeLeftValueLabel.text = @"--:--";
        
        if(playerItem && CMTIME_IS_VALID(playerItem.duration)){
            
              float duration  = CMTimeGetSeconds(playerItem.duration);
            
              self.valueLabel.text = RTSTimeSliderFormatter(0);
              self.timeLeftValueLabel.text = RTSTimeSliderFormatter(-duration);
        
        } else {
        
            self.valueLabel.text = @"--:--";
            self.timeLeftValueLabel.text = @"--:--";

        }
//FIX<-


		return;
	}
	
	if (self.live)
	{
		self.valueLabel.text = @"--:--";
		self.timeLeftValueLabel.text = RTSMediaPlayerLocalizedString(@"Live", nil);
	}
	else {
		self.valueLabel.text = RTSTimeSliderFormatter(self.value);
		self.timeLeftValueLabel.text = RTSTimeSliderFormatter(self.value - self.maximumValue);
	}
}


#pragma mark Touch tracking

- (BOOL) beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	BOOL beginTracking = [super beginTrackingWithTouch:touch withEvent:event];
	if (! beginTracking || ! [self isDraggable]) {
		return NO;
	}
	
	return beginTracking;
}

- (BOOL) continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	BOOL continueTracking = [super continueTrackingWithTouch:touch withEvent:event];
	
	if (continueTracking && [self isDraggable]) {
		[self updateTimeRangeLabels];
		[self setNeedsDisplay];
	}
	
	CMTime time = self.time;
	
	if (self.seekingDuringTracking) {
		[self.mediaPlayerController seekToTime:time completionHandler:nil];
	}
	
	// Next, inform that we are sliding to other views.
	[self.slidingDelegate timeSlider:self
			 isMovingToPlaybackTime:time
						   withValue:self.value
						 interactive:YES];
	
	return continueTracking;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	if ([self isDraggable]) {
		[self.mediaPlayerController playAtTime:self.time];
	}
	
	[super endTrackingWithTouch:touch withEvent:event];
}

#pragma mark - Slider Appearance

- (UIImage *)emptyImage
{
	UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 2, 2)];
	UIGraphicsBeginImageContextWithOptions(view.frame.size, NO, 0);
	[view.layer renderInContext:UIGraphicsGetCurrentContext()];
	[[UIColor clearColor] set];
	UIImage *viewImage = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	
	return viewImage;
}

- (UIImage *)thumbImage
{
	UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 15, 15)];
	return [path imageWithColor:self.thumbTintColor];
}



#pragma mark - Draw Methods

- (void)drawRect:(CGRect)rect
{
	[super drawRect:rect];
	
	CGContextRef context = UIGraphicsGetCurrentContext();
	[self drawBar:context];
	[self drawDownloadProgressValueBar:context];
	[self drawMinimumValueBar:context];
}

- (void)drawBar:(CGContextRef)context
{
	CGRect trackFrame = [self trackRectForBounds:self.bounds];
	
	CGFloat lineWidth = 3.0f;
	
	CGContextSetLineWidth(context, lineWidth);
	CGContextSetLineCap(context, kCGLineCapRound);
	CGContextMoveToPoint(context, CGRectGetMinX(trackFrame), SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context, CGRectGetWidth(trackFrame), SLIDER_VERTICAL_CENTER);
	CGContextSetStrokeColorWithColor(context, self.borderColor.CGColor);
	CGContextStrokePath(context);
}

- (void)drawDownloadProgressValueBar:(CGContextRef)context
{
	CGRect trackFrame = [self trackRectForBounds:self.bounds];
	
	CGFloat lineWidth = 1.0f;
	
	CGContextSetLineWidth(context, lineWidth);
	CGContextSetLineCap(context, kCGLineCapButt);
	CGContextMoveToPoint(context, CGRectGetMinX(trackFrame)+2, SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context, CGRectGetMaxX(trackFrame)-2, SLIDER_VERTICAL_CENTER);
	CGContextSetStrokeColorWithColor(context, self.maximumTrackTintColor.CGColor);
	CGContextStrokePath(context);
	
	for (NSValue *value in self.mediaPlayerController.playerItem.loadedTimeRanges) {
		CMTimeRange timeRange = [value CMTimeRangeValue];
		[self drawTimeRangeProgress:timeRange context:context];
	}
}

- (void)drawTimeRangeProgress:(CMTimeRange)timeRange context:(CGContextRef)context
{
	CGFloat lineWidth = 1.0f;
	
	CGFloat duration = CMTimeGetSeconds(self.mediaPlayerController.playerItem.duration);
	if (isnan(duration))
		return;
	
	CGRect trackFrame = [self trackRectForBounds:self.bounds];
	
	CGFloat minX = CGRectGetWidth(trackFrame) / duration * CMTimeGetSeconds(timeRange.start);
	CGFloat maxX = CGRectGetWidth(trackFrame) / duration * (CMTimeGetSeconds(timeRange.start)+CMTimeGetSeconds(timeRange.duration));
	
	CGContextSetLineWidth(context, lineWidth);
	CGContextSetLineCap(context,kCGLineCapButt);
	CGContextMoveToPoint(context, minX, SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context, maxX, SLIDER_VERTICAL_CENTER);
	CGContextSetStrokeColorWithColor(context, self.borderColor.CGColor);
	CGContextStrokePath(context);
}

- (void)drawMinimumValueBar:(CGContextRef)context
{
	CGRect barFrame = [self minimumValueImageRectForBounds:self.bounds];
	
	CGFloat lineWidth = 3.0f;
	
	CGContextSetLineWidth(context, lineWidth);
	CGContextSetLineCap(context,kCGLineCapRound);
	CGContextMoveToPoint(context,CGRectGetMinX(barFrame)-0.5, SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context, CGRectGetWidth(barFrame), SLIDER_VERTICAL_CENTER);
	CGContextSetStrokeColorWithColor(context, self.minimumTrackTintColor.CGColor);
	CGContextStrokePath(context);
}

#pragma mark - Overrides

// Take into account the non-standard smaller knob we installed in -setup_RTSTimeSlider

- (CGRect) minimumValueImageRectForBounds:(CGRect)bounds
{
	CGRect trackFrame = [super trackRectForBounds:self.bounds];
	CGRect thumbRect = [super thumbRectForBounds:self.bounds trackRect:trackFrame value:self.value];
	return CGRectMake(CGRectGetMinX(trackFrame),
					  CGRectGetMinY(trackFrame),
					  CGRectGetMidX(thumbRect) - CGRectGetMinX(trackFrame),
					  CGRectGetHeight(trackFrame));
}

- (CGRect) maximumValueImageRectForBounds:(CGRect)bounds
{
	CGRect trackFrame = [super trackRectForBounds:self.bounds];
	CGRect thumbRect = [super thumbRectForBounds:self.bounds trackRect:trackFrame value:self.value];
	return CGRectMake(CGRectGetMidX(thumbRect),
					  CGRectGetMinY(trackFrame),
					  CGRectGetMaxX(trackFrame) - CGRectGetMidX(thumbRect),
					  CGRectGetHeight(trackFrame));
}

- (float)resetValue
{
    return (self.knobLivePosition == RTSTimeSliderLiveKnobPositionLeft) ? 0. : 1.;
}

- (void)willMoveToWindow:(UIWindow *)window
{
	[super willMoveToWindow:window];
	
	if (window) {
		@weakify(self)
		self.periodicTimeObserver = [self.mediaPlayerController addPeriodicTimeObserverForInterval:CMTimeMake(1., 5.) queue:NULL usingBlock:^(CMTime time) {
			@strongify(self)
			
			if (!self.isTracking && self.mediaPlayerController.playbackState != RTSMediaPlaybackStateSeeking)
			{
				CMTimeRange timeRange = [self.mediaPlayerController timeRange];
                if (self.mediaPlayerController.streamType == RTSMediaStreamTypeOnDemand
                        && (self.mediaPlayerController.playbackState == RTSMediaPlaybackStateIdle || self.mediaPlayerController.playbackState == RTSMediaPlaybackStateEnded)) {

                    if(!CMTIMERANGE_IS_EMPTY(timeRange) && !CMTIMERANGE_IS_INDEFINITE(timeRange) && !CMTIMERANGE_IS_INVALID(timeRange)){
                        self.maximumValue = CMTimeGetSeconds(timeRange.duration);
                    } else {
                        self.maximumValue = 0.f;
                    }
                    
                    self.value = 0.f;
                    self.userInteractionEnabled = YES;
                }
                else if(!CMTIMERANGE_IS_EMPTY(timeRange) && !CMTIMERANGE_IS_INDEFINITE(timeRange) && !CMTIMERANGE_IS_INVALID(timeRange))
				{
					self.maximumValue = CMTimeGetSeconds(timeRange.duration);
					
					AVPlayerItem *playerItem = self.mediaPlayerController.playerItem;
					self.value = CMTimeGetSeconds(CMTimeSubtract(playerItem.currentTime, timeRange.start));
					self.userInteractionEnabled = YES;
				}
				else
				{
                    float value = [self resetValue];
                    self.maximumValue = value;
					self.value = value;
					self.userInteractionEnabled = NO;
				}
				
				RTSMediaPlayerLogTrace(@"Range min = %@ (value = %@) --- Current = %@ (value = %@) --- Range max = %@ (value = %@)",
									   @(CMTimeGetSeconds(timeRange.start)), @(self.minimumValue),
									   @(CMTimeGetSeconds(self.mediaPlayerController.playerItem.currentTime)), @(self.value),
									   @(CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange))), @(self.maximumValue));
				
				[self.slidingDelegate timeSlider:self
						  isMovingToPlaybackTime:self.time
									   withValue:self.value
									 interactive:NO];
				
				[self setNeedsDisplay];
				[self updateTimeRangeLabels];
			}
		}];
		
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(timesliderPlaybackStateDidChange:)
													 name:RTSMediaPlayerPlaybackStateDidChangeNotification
												   object:self.mediaPlayerController];
	}
	else {
		[self.mediaPlayerController removePeriodicTimeObserver:self.periodicTimeObserver];
		[[NSNotificationCenter defaultCenter] removeObserver:self
														name:RTSMediaPlayerPlaybackStateDidChangeNotification
													  object:self.mediaPlayerController];
	}
}

#pragma mark Notifications

- (void)timesliderPlaybackStateDidChange:(NSNotification *)notification
{
	if (self.mediaPlayerController.playbackState == RTSMediaPlaybackStateIdle
			|| self.mediaPlayerController.playbackState == RTSMediaPlaybackStateEnded) {
        float value = [self resetValue];
		self.value = value;
        self.maximumValue = value;
		
		[self.slidingDelegate timeSlider:self
				  isMovingToPlaybackTime:self.time
							   withValue:self.value
							 interactive:NO];
		
		[self setNeedsDisplay];
		[self updateTimeRangeLabels];
	}
}

@end
