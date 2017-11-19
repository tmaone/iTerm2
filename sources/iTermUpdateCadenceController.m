//
//  iTermUpdateCadenceController.m
//  iTerm2
//
//  Created by George Nachman on 8/1/17.
//
//

#import "iTermUpdateCadenceController.h"

#import "DebugLogging.h"
#import "NSTimer+iTerm.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermThroughputEstimator.h"

// Timer period between updates when active (not idle, tab is visible or title bar is changing,
// etc.)
static const NSTimeInterval kActiveUpdateCadence = 1 / 20.0;

// Timer period between updates when adaptive frame rate is enabled and throughput is low but not 0.
static const NSTimeInterval kFastUpdateCadence = 1.0 / 60.0;

// Timer period for background sessions. This changes the tab item's color
// so it must run often enough for that to be useful.
// TODO(georgen): There's room for improvement here.
static const NSTimeInterval kBackgroundUpdateCadence = 1;


@implementation iTermUpdateCadenceController {
    BOOL _useGCDUpdateTimer;
    // This timer fires periodically to redraw textview, update the scroll position, tab appearance,
    // etc.
    NSTimer *_updateTimer;

    // This is the experimental GCD version of the update timer that seems to have more regular refreshes.
    dispatch_source_t _gcdUpdateTimer;
    NSTimeInterval _cadence;
    
    BOOL _deferredCadenceChange;

    iTermThroughputEstimator *_throughputEstimator;
}

- (instancetype)initWithThroughputEstimator:(iTermThroughputEstimator *)throughputEstimator {
    self = [super init];
    if (self) {
        _useGCDUpdateTimer = [iTermAdvancedSettingsModel useGCDUpdateTimer];
        _throughputEstimator = throughputEstimator;
    }
    return self;
}

- (void)dealloc {
    if (_gcdUpdateTimer != nil) {
        dispatch_source_cancel(_gcdUpdateTimer);
    }
    [_updateTimer invalidate];
}

- (void)changeCadenceIfNeeded {
    [self changeCadenceIfNeeded:NO];
}

- (void)willStartLiveResize {
    if (!_useGCDUpdateTimer && _updateTimer) {
        [[NSRunLoop currentRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)liveResizeDidEnd {
    if (_useGCDUpdateTimer) {
        NSTimeInterval cadence = _cadence;
        _cadence = 0;
        [self setUpdateCadence:cadence liveResizing:NO force:NO];
    } else {
        if (_updateTimer) {
            NSTimeInterval cadence = _updateTimer.timeInterval;
            [_updateTimer invalidate];
            _updateTimer = nil;
            [self setUpdateCadence:cadence liveResizing:NO force:NO];
        }
    }
}

#pragma mark - Private

- (void)changeCadenceIfNeeded:(BOOL)force {
    iTermUpdateCadenceState state = [_delegate updateCadenceControllerState];

    BOOL effectivelyActive = (state.active || !state.idle || [NSApp isActive]);
    if (effectivelyActive && state.visible) {
        if (state.useAdaptiveFrameRate) {
            const NSInteger kThroughputLimit = state.adaptiveFrameRateThroughputThreshold;
            const NSInteger estimatedThroughput = [_throughputEstimator estimatedThroughput];
            if (estimatedThroughput < kThroughputLimit && estimatedThroughput > 0) {
                [self setUpdateCadence:kFastUpdateCadence liveResizing:state.liveResizing force:force];
            } else {
                [self setUpdateCadence:1.0 / state.slowFrameRate liveResizing:state.liveResizing force:force];
            }
        } else {
            [self setUpdateCadence:kActiveUpdateCadence liveResizing:state.liveResizing force:force];
        }
    } else {
        [self setUpdateCadence:kBackgroundUpdateCadence liveResizing:state.liveResizing force:force];
    }
}

- (void)setUpdateCadence:(NSTimeInterval)cadence liveResizing:(BOOL)liveResizing force:(BOOL)force {
    if (_useGCDUpdateTimer) {
        [self setGCDUpdateCadence:cadence liveResizing:liveResizing force:force];
    } else {
        [self setTimerUpdateCadence:cadence liveResizing:liveResizing force:force];
    }
}

- (void)setTimerUpdateCadence:(NSTimeInterval)cadence liveResizing:(BOOL)liveResizing force:(BOOL)force {
    if (_updateTimer.timeInterval == cadence) {
        DLog(@"No change to cadence.");
        return;
    }
    DLog(@"Set cadence of %@ to %f", self.delegate, cadence);

    if (liveResizing) {
        // This solves the bug where we don't redraw properly during live resize.
        // I'm worried about the possible side effects it might have since there's no way to
        // know all the tracking event loops.
        [_updateTimer invalidate];
        _updateTimer = [NSTimer weakTimerWithTimeInterval:kActiveUpdateCadence
                                                   target:self
                                                 selector:@selector(updateDisplay)
                                                 userInfo:nil
                                                  repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
    } else {
        if (!force && _updateTimer && cadence > _updateTimer.timeInterval) {
            DLog(@"Defer cadence change");
            _deferredCadenceChange = YES;
        } else {
            [_updateTimer invalidate];
            _updateTimer = [NSTimer scheduledWeakTimerWithTimeInterval:cadence
                                                                target:self
                                                              selector:@selector(updateDisplay)
                                                              userInfo:nil
                                                               repeats:YES];
        }
    }
}
- (void)setGCDUpdateCadence:(NSTimeInterval)cadence liveResizing:(BOOL)liveResizing force:(BOOL)force {
    const NSTimeInterval period = liveResizing ? kActiveUpdateCadence : cadence;
    if (_cadence == period) {
        DLog(@"No change to cadence.");
        return;
    }
    DLog(@"Set cadence of %@ to %f", self.delegate, cadence);

    if (!force && _cadence > 0 && cadence > _cadence) {
        // Don't increase the cadence until after the screen has a chance to
        // draw. This way if you do "cat bigfile.txt" you see the first
        // screenful before the refresh rate drops. This way you know
        // something's happening.
        DLog(@"Defer cadence change");
        _deferredCadenceChange = YES;
        return;
    }

    _cadence = period;

    if (_gcdUpdateTimer != nil) {
        dispatch_source_cancel(_gcdUpdateTimer);
        _gcdUpdateTimer = nil;
    }

    _gcdUpdateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_gcdUpdateTimer,
                              dispatch_time(DISPATCH_TIME_NOW, period * NSEC_PER_SEC),
                              period * NSEC_PER_SEC,
                              0.005 * NSEC_PER_SEC);
    __weak __typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_gcdUpdateTimer, ^{
        [weakSelf updateDisplay];
    });
    dispatch_resume(_gcdUpdateTimer);
}

- (BOOL)updateTimerIsValid {
    if (_useGCDUpdateTimer) {
        return _gcdUpdateTimer != nil;
    } else {
        return _updateTimer.isValid;
    }
}

- (void)updateDisplay {
    if (_deferredCadenceChange) {
        [self changeCadenceIfNeeded:YES];
        _deferredCadenceChange = NO;
    }
    [_delegate updateCadenceControllerUpdateDisplay:self];
}

@end
