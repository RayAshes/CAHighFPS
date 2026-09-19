#define CHECK_TARGET

#import <PSHeader/PS.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#define domain CFSTR("com.apple.UIKit")
#define whitelistKey CFSTR("CAHighFPS")
#define systemWideKey CFSTR("CAHighFPSSystemWide")
#define blacklistKey CFSTR("CAHighFPSBlacklist")
#define customFPSKey CFSTR("CAHighFPSCustomFPS")

@interface CAMetalLayer (Private)
@property (assign) CGFloat drawableTimeoutSeconds;
@end

#ifndef __IPHONE_15_0
typedef struct {
    NSInteger minimum;
    NSInteger preferred;
    NSInteger maximum;
} CAFrameRateRange;
#endif

static NSInteger maxFPS = -1;
static NSInteger customFPS = 0;
static BOOL systemWide = NO;
static NSArray<NSString *> *whitelist;
static NSArray<NSString *> *blacklist;

static id copyPrefValue(CFStringRef prefKey) {
    CFTypeRef value = CFPreferencesCopyAppValue(prefKey, domain);
    if (value == NULL)
        value = CFPreferencesCopyValue(prefKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return value ? (__bridge_transfer id)value : nil;
}

static void loadPreferences() {
    id systemWideValue = copyPrefValue(systemWideKey);
    systemWide = [systemWideValue isKindOfClass:[NSNumber class]] && [systemWideValue boolValue];

    id whitelistValue = copyPrefValue(whitelistKey);
    whitelist = [whitelistValue isKindOfClass:[NSArray class]] ? whitelistValue : nil;

    id blacklistValue = copyPrefValue(blacklistKey);
    blacklist = [blacklistValue isKindOfClass:[NSArray class]] ? blacklistValue : nil;

    id customFPSValue = copyPrefValue(customFPSKey);
    customFPS = [customFPSValue isKindOfClass:[NSNumber class]] ? (NSInteger)lround([customFPSValue doubleValue]) : 0;
}

static NSInteger getMaxFPS() {
    if (maxFPS == -1)
        maxFPS = [UIScreen mainScreen].maximumFramesPerSecond;
    return maxFPS;
}

static NSInteger getTargetFPS() {
    NSInteger max = getMaxFPS();
    if (customFPS <= 0 || customFPS >= max)
        return max;
    return customFPS;
}

static BOOL usesCustomFPS() {
    NSInteger max = getMaxFPS();
    return customFPS > 0 && customFPS < max;
}

static BOOL shouldEnableForBundleIdentifier(NSString *bundleIdentifier) {
    // ↓↓↓ 原版屏蔽桌面的这一行已经移除！
    // if ([bundleIdentifier isEqualToString:@"com.apple.springboard"])
    //     return NO;

    if (systemWide)
        return ![blacklist containsObject:bundleIdentifier];
    return [whitelist containsObject:bundleIdentifier];
}

#pragma mark - CADisplayLink

%hook CADisplayLink

- (void)setFrameInterval:(NSInteger)interval {
    NSInteger target = getTargetFPS();
    NSInteger newInterval = (NSInteger)lround((double)getMaxFPS() / (double)target);
    %orig(newInterval < 1 ? 1 : newInterval);
    if ([self respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        self.preferredFramesPerSecond = usesCustomFPS() ? target : 0;
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    %orig(usesCustomFPS() ? getTargetFPS() : 0);
}

// ———— 这里是关键修正：真正 Range / PFPS 10～target ————
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    NSInteger target = getTargetFPS();
    if (usesCustomFPS()) {
        range.minimum   = 10;
        range.preferred = target;
        range.maximum   = target;
    } else {
        // 不启用时交还系统原生区间
        range.minimum   = 10;
        range.preferred = getMaxFPS();
        range.maximum   = getMaxFPS();
    }
    %orig;
}

%end

#pragma mark - CAMetalLayer

%hook CAMetalLayer

- (NSUInteger)maximumDrawableCount {
    return 2;
}

- (void)setMaximumDrawableCount:(NSUInteger)count {
    %orig(2);
}

%end

#pragma mark - Metal Advanced Hack

%hook CAMetalDrawable

- (void)presentAfterMinimumDuration:(CFTimeInterval)duration {
    %orig(1.0 / getTargetFPS());
}

%end

%hook MTLCommandBuffer

- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)minimumDuration {
    %orig(drawable, 1.0 / getTargetFPS());
}

%end

// UIKit 那组函数原版注释有坑，保留注释不动即可
// #pragma mark - UIKit
// BOOL (*_UIUpdateCycleSchedulerEnabled)(void);
// %group UIKit
// %hookf(BOOL, _UIUpdateCycleSchedulerEnabled) { return YES; }
// %end

%ctor {
    loadPreferences();
    if (isTarget(TargetTypeApps) && shouldEnableForBundleIdentifier(NSBundle.mainBundle.bundleIdentifier)) {
        %init;
    }
}
