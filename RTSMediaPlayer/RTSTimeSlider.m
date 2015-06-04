//
//  Copyright (c) RTS. All rights reserved.
//
//  Licence information is available from the LICENCE file.
//

#import <RTSMediaPlayer/RTSMediaPlayerController.h>
#import <libextobjc/EXTScope.h>
#import "RTSTimeSlider.h"
#import "UIBezierPath+RTSMediaPlayerUtils.h"

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

@property (weak) id playbackTimeObserver;

@end

@implementation RTSTimeSlider

#pragma mark - initialization

- (id) initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		[self setup];
	}
	return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self) {
		[self setup];
	}
	return self;
}

- (void)setup
{
	UIImage *triangle = [self emptyImage];
	UIImage *image = [triangle resizableImageWithCapInsets:UIEdgeInsetsMake(1, 1, 1, 1)];
	
	[self setMinimumTrackImage:image forState:UIControlStateNormal];
	[self setMaximumTrackImage:image forState:UIControlStateNormal];
	
	[self setThumbImage:[self thumbImage] forState:UIControlStateNormal];
	[self setThumbImage:[self thumbImage] forState:UIControlStateHighlighted];
	
	[self addTarget:self action:@selector(informDelegate:) forControlEvents:UIControlEventValueChanged];
}

#pragma mark - Setters and getters

- (void) setPlaybackController:(id<RTSMediaPlayback>)playbackController
{
	if (_playbackController)
	{
		[_playbackController removePlaybackTimeObserver:self.playbackTimeObserver];
	}
	
	_playbackController = playbackController;
	
	@weakify(self)
	self.playbackTimeObserver = [playbackController addPlaybackTimeObserverForInterval:CMTimeMake(1., 5.) queue:NULL usingBlock:^(CMTime time) {
		@strongify(self)
		
		if (!self.isTracking)
		{
			CMTimeRange currentTimeRange = [self currentTimeRange];
			if (!CMTIMERANGE_IS_EMPTY(currentTimeRange))
			{
				self.minimumValue = CMTimeGetSeconds(currentTimeRange.start);
				self.maximumValue = CMTimeGetSeconds(CMTimeRangeGetEnd(currentTimeRange));
				
				AVPlayerItem *playerItem = self.playbackController.playerItem;
				self.value = CMTimeGetSeconds(playerItem.currentTime);
			}
			else
			{
				self.minimumValue = 0.;
				self.maximumValue = 0.;
				self.value = 0.;
			}
		}
		[self updateTimeRangeLabels];
		[self setNeedsDisplay];
	}];
}

- (BOOL)isDraggable
{
	// A slider knob can be dragged iff it corresponds to a valid range
	return self.minimumValue != self.maximumValue;
}


#pragma mark - Time range retrieval and display

- (CMTimeRange)currentTimeRange
{
	// TODO: Should later add support for discontinuous seekable time ranges
	AVPlayerItem *playerItem = self.playbackController.playerItem;
	NSValue *seekableTimeRangeValue = [playerItem.seekableTimeRanges firstObject];
	if (seekableTimeRangeValue) {
		CMTimeRange seekableTimeRange = [seekableTimeRangeValue CMTimeRangeValue];
		return CMTIMERANGE_IS_VALID(seekableTimeRange) ? seekableTimeRange : kCMTimeRangeZero;
	}
	else {
		return kCMTimeRangeZero;
	}
}


// Useful for live streams. How does it work for VOD?
- (CMTime)time
{
    CMTimeRange currentTimeRange = [self currentTimeRange];
    Float64 timeInSeconds = CMTimeGetSeconds(currentTimeRange.start) + (self.value - self.minimumValue) * CMTimeGetSeconds(currentTimeRange.duration) / (self.maximumValue - self.minimumValue);
    return CMTimeMakeWithSeconds(timeInSeconds, 1.);
}

- (CMTime)convertedValueCMTime
{
	CGFloat fraction = (self.value - self.minimumValue) / (self.maximumValue - self.minimumValue);
	CGFloat duration = CMTimeGetSeconds(self.playbackController.playerItem.duration);
	// Assuming start == 0.
	return CMTimeMakeWithSeconds(fraction*duration, NSEC_PER_SEC);
}

- (void)updateTimeRangeLabels
{
	CMTimeRange currentTimeRange = [self currentTimeRange];
	AVPlayerItem *playerItem = self.playbackController.playerItem;

	// Live and timeshift feeds in live conditions. This happens when either the following condition
	// is met:
	//  - We have a pure live feed, which is characterized by an empty range
	//  - We have a timeshift feed, which is characterized by an indefinite player item duration, and which is close
	//    to now. We consider a timeshift 'close to now' when the slider is at the end, up to a tolerance of 15 seconds
	static const float RTSToleranceInSeconds = 15.f;
	
	if (CMTIMERANGE_IS_EMPTY(currentTimeRange)
		|| (CMTIME_IS_INDEFINITE(playerItem.duration) && (self.maximumValue - self.value < RTSToleranceInSeconds)))
	{
		self.valueLabel.text = @"--:--";
		self.timeLeftValueLabel.text = @"LIVE";
		
		// TODO: Should be configurable. Will conflict with changes made to the labels
		self.timeLeftValueLabel.textColor = [UIColor whiteColor];
		self.timeLeftValueLabel.backgroundColor = [UIColor redColor];
	}
	// Video on demand
	else {
		self.valueLabel.text = RTSTimeSliderFormatter(self.value);
		self.timeLeftValueLabel.text = RTSTimeSliderFormatter(self.value - self.maximumValue);
		
		// TODO: Should be configurable. Will conflict with changes made to the labels
		self.timeLeftValueLabel.textColor = [UIColor blackColor];
		self.timeLeftValueLabel.backgroundColor = [UIColor clearColor];
	}
}


#pragma mark Touch tracking

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	BOOL beginTracking = [super beginTrackingWithTouch:touch withEvent:event];
	if (beginTracking && [self isDraggable]) {
		[self.playbackController pause];
	}
	
	return beginTracking;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	BOOL continueTracking = [super continueTrackingWithTouch:touch withEvent:event];
	if (continueTracking && [self isDraggable]) {
		[self updateTimeRangeLabels];
		[self setNeedsDisplay];
	}
	
	return continueTracking;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	if ([self isDraggable] && self.tracking) {
		// No completion handler, to not guess what's suppose to happen next once seeking is over.
		[self.playbackController seekToTime:CMTimeMakeWithSeconds(self.value, 1) completionHandler:nil];
	}
	
	[super endTrackingWithTouch:touch withEvent:event];
}

- (void)informDelegate:(id)sender
{
	if (self.seekingDelegate) {
		[self.seekingDelegate timeSlider:self
						 isSeekingAtTime:[self convertedValueCMTime]
							   withValue:self.value];
	}
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
	return [path imageWithColor:[UIColor whiteColor]];
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
	CGContextSetLineCap(context,kCGLineCapRound);
	CGContextMoveToPoint(context,CGRectGetMinX(trackFrame), SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context,CGRectGetWidth(trackFrame), SLIDER_VERTICAL_CENTER);
	CGContextSetStrokeColorWithColor(context, [UIColor blackColor].CGColor);
	CGContextStrokePath(context);
}

- (void)drawDownloadProgressValueBar:(CGContextRef)context
{
	CGRect trackFrame = [self trackRectForBounds:self.bounds];

	CGFloat lineWidth = 1.0f;
	
	CGContextSetLineWidth(context, lineWidth);
	CGContextSetLineCap(context,kCGLineCapButt);
	CGContextMoveToPoint(context,CGRectGetMinX(trackFrame)+2, SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context,CGRectGetMaxX(trackFrame)-2, SLIDER_VERTICAL_CENTER);
	CGContextSetStrokeColorWithColor(context, [UIColor darkGrayColor].CGColor);
	CGContextStrokePath(context);
	
	for (NSValue *value in self.playbackController.playerItem.loadedTimeRanges) {
		CMTimeRange timeRange = [value CMTimeRangeValue];
		[self drawTimeRangeProgress:timeRange context:context];
	}
}

- (void)drawTimeRangeProgress:(CMTimeRange)timeRange context:(CGContextRef)context
{
	CGFloat lineWidth = 1.0f;
	
	CGFloat duration = CMTimeGetSeconds(self.playbackController.playerItem.duration);
	if (isnan(duration))
		return;
	
	CGRect trackFrame = [self trackRectForBounds:self.bounds];
	
	CGFloat minX = CGRectGetWidth(trackFrame) / duration * CMTimeGetSeconds(timeRange.start);
	CGFloat maxX = CGRectGetWidth(trackFrame) / duration * (CMTimeGetSeconds(timeRange.start)+CMTimeGetSeconds(timeRange.duration));
	
	CGContextSetLineWidth(context, lineWidth);
	CGContextSetLineCap(context,kCGLineCapButt);
	CGContextMoveToPoint(context, minX, SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context, maxX, SLIDER_VERTICAL_CENTER);
	// TODO: We should be able to customise this color
	CGContextSetStrokeColorWithColor(context, [UIColor blackColor].CGColor);
	CGContextStrokePath(context);
}

- (void)drawMinimumValueBar:(CGContextRef)context
{
	CGRect trackFrame = [self trackRectForBounds:self.bounds];
	CGRect thumbRect = [self thumbRectForBounds:self.bounds trackRect:trackFrame value:self.value];
	
	CGFloat lineWidth = 3.0f;
	
	CGContextSetLineWidth(context, lineWidth);
	CGContextSetLineCap(context,kCGLineCapRound);
	CGContextMoveToPoint(context,CGRectGetMinX(trackFrame), SLIDER_VERTICAL_CENTER);
	CGContextAddLineToPoint(context,CGRectGetMidX(thumbRect), SLIDER_VERTICAL_CENTER);
	// TODO: We should be able to customise this color
	CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
	CGContextStrokePath(context);
}



@end
