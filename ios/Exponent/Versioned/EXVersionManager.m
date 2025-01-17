// Copyright 2015-present 650 Industries. All rights reserved.

#import "EXAppState.h"
#import "EXDevSettings.h"
#import "EXDisabledDevLoadingView.h"
#import "EXDisabledDevMenu.h"
#import "EXDisabledRedBox.h"
#import "EXFileSystem.h"
#import "EXFrameExceptionsManager.h"
#import "EXKernelModule.h"
#import "EXVersionManager.h"
#import "EXStatusBarManager.h"
#import "EXUnversioned.h"
#import "EXTest.h"

#import <React/RCTAssert.h>
#import <React/RCTBridge.h>
#import <React/RCTBridge+Private.h>
#import <React/RCTDevMenu.h>
#import <React/RCTDevSettings.h>
#import <React/RCTLog.h>
#import <React/RCTModuleData.h>
#import <React/RCTUtils.h>

#import <React/RCTAsyncLocalStorage.h>

#import <objc/message.h>

static NSNumber *EXVersionManagerIsFirstLoad;

// used for initializing scoped modules which don't tie in to any kernel service.
#define EX_KERNEL_SERVICE_NONE @"EXKernelServiceNone"

// this is needed because RCTPerfMonitor does not declare a public interface
// anywhere that we can import.
@interface RCTPerfMonitorDevSettingsHack <NSObject>

- (void)hide;
- (void)show;

@end

static NSMutableDictionary<NSString *, NSString *> *EXScopedModuleClasses;
void EXRegisterScopedModule(Class, NSString *);
void EXRegisterScopedModule(Class moduleClass, NSString *kernelServiceClassName)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    EXScopedModuleClasses = [NSMutableDictionary dictionary];
  });
  
  NSString *unversionedKernelServiceClassName;
  if ([kernelServiceClassName isEqualToString:@"nil"]) {
    unversionedKernelServiceClassName = EX_KERNEL_SERVICE_NONE;
  } else {
    unversionedKernelServiceClassName = [EX_UNVERSIONED(@"EX") stringByAppendingString:kernelServiceClassName];
  }
  NSString *moduleClassName = NSStringFromClass(moduleClass);
  if (moduleClassName) {
    EXScopedModuleClasses[moduleClassName] = unversionedKernelServiceClassName;
  }
}

@interface EXVersionManager ()

// is this the first time this ABI has been touched at runtime?
@property (nonatomic, assign) BOOL isFirstLoad;

@end

@implementation EXVersionManager

- (instancetype)initWithFatalHandler:(void (^)(NSError *))fatalHandler
                         logFunction:(void (^)(NSInteger, NSInteger, NSString *, NSNumber *, NSString *))logFunction
                        logThreshold:(NSInteger)threshold
{
  if (self = [super init]) {
    [self configureABIWithFatalHandler:fatalHandler logFunction:logFunction logThreshold:threshold];
  }
  return self;
}

- (void)bridgeWillStartLoading:(id)bridge
{
  // manually send a "start loading" notif, since the real one happened uselessly inside the RCTBatchedBridge constructor
  [[NSNotificationCenter defaultCenter]
   postNotificationName:RCTJavaScriptWillStartLoadingNotification object:bridge];
}

- (void)bridgeFinishedLoading
{

}

- (void)bridgeDidForeground
{
  if (_isFirstLoad) {
    _isFirstLoad = NO; // in case the same VersionManager instance is used between multiple bridge loads
  } else {
    // some state is shared between bridges, for example status bar
    [self resetSharedState];
  }
}

- (void)bridgeDidBackground
{
  [self saveSharedState];
}

- (void)saveSharedState
{

}

- (void)resetSharedState
{

}

- (void)invalidate
{

}

- (NSDictionary<NSString *, NSString *> *)devMenuItemsForBridge:(id)bridge
{
  RCTDevSettings *devSettings = [self _moduleInstanceForBridge:bridge named:@"DevSettings"];
  NSMutableDictionary *items = [@{
    @"dev-reload": @{ @"label": @"Reload", @"isEnabled": @YES },
    @"dev-inspector": @{ @"label": @"Toggle Element Inspector", @"isEnabled": @YES },
  } mutableCopy];
  if (devSettings.isRemoteDebuggingAvailable) {
    items[@"dev-remote-debug"] = @{
      @"label": (devSettings.isDebuggingRemotely) ? @"Stop Remote Debugging" : @"Debug Remote JS",
      @"isEnabled": @YES
    };
  } else {
    items[@"dev-remote-debug"] =  @{ @"label": @"Remote Debugger Unavailable", @"isEnabled": @NO };
  }
  if (devSettings.isLiveReloadAvailable && !devSettings.isHotLoadingEnabled) {
    items[@"dev-live-reload"] = @{
      @"label": (devSettings.isLiveReloadEnabled) ? @"Disable Live Reload" : @"Enable Live Reload",
      @"isEnabled": @YES,
    };
    items[@"dev-profiler"] = @{
      @"label": (devSettings.isProfilingEnabled) ? @"Stop Systrace" : @"Start Systrace",
      @"isEnabled": @YES,
    };
  } else {
    NSMutableDictionary *liveReloadItem = [@{ @"label": @"Live Reload Unavailable", @"isEnabled": @NO } mutableCopy];
    if (devSettings.isHotLoadingEnabled) {
      liveReloadItem[@"detail"] = @"You can't use Live Reload and Hot Reloading at the same time. Disable Hot Reloading to use Live Reload.";
    }
    items[@"dev-live-reload"] =  liveReloadItem;
  }
  if (devSettings.isHotLoadingAvailable && !devSettings.isLiveReloadEnabled) {
    items[@"dev-hmr"] = @{
      @"label": (devSettings.isHotLoadingEnabled) ? @"Disable Hot Reloading" : @"Enable Hot Reloading",
      @"isEnabled": @YES,
    };
  } else {
    NSMutableDictionary *hmrItem = [@{ @"label": @"Hot Reloading Unavailable", @"isEnabled": @NO } mutableCopy];
    if (devSettings.isLiveReloadEnabled) {
      hmrItem[@"detail"] = @"You can't use Live Reload and Hot Reloading at the same time. Disable Live Reload to use Hot Reloading.";
    }
    items[@"dev-hmr"] =  hmrItem;
  }
  if (devSettings.isJSCSamplingProfilerAvailable) {
    items[@"dev-jsc-profiler"] = @{ @"label": @"Start / Stop JS Sampling Profiler", @"isEnabled": @YES };
  }
  id perfMonitor = [self _moduleInstanceForBridge:bridge named:@"PerfMonitor"];
  if (perfMonitor) {
    items[@"dev-perf-monitor"] = @{
      @"label": devSettings.isPerfMonitorShown ? @"Hide Perf Monitor" : @"Show Perf Monitor",
      @"isEnabled": @YES,
    };
  }

  return items;
}

- (void)selectDevMenuItemWithKey:(NSString *)key onBridge:(id)bridge
{
  RCTAssertMainThread();
  RCTDevSettings *devSettings = [self _moduleInstanceForBridge:bridge named:@"DevSettings"];
  if ([key isEqualToString:@"dev-reload"]) {
    [bridge reload];
  } else if ([key isEqualToString:@"dev-remote-debug"]) {
    devSettings.isDebuggingRemotely = !devSettings.isDebuggingRemotely;
  } else if ([key isEqualToString:@"dev-live-reload"]) {
    devSettings.isLiveReloadEnabled = !devSettings.isLiveReloadEnabled;
  } else if ([key isEqualToString:@"dev-profiler"]) {
    devSettings.isProfilingEnabled = !devSettings.isProfilingEnabled;
  } else if ([key isEqualToString:@"dev-hmr"]) {
    devSettings.isHotLoadingEnabled = !devSettings.isHotLoadingEnabled;
  } else if ([key isEqualToString:@"dev-jsc-profiler"]) {
    [devSettings toggleJSCSamplingProfiler];
  } else if ([key isEqualToString:@"dev-inspector"]) {
    [devSettings toggleElementInspector];
  } else if ([key isEqualToString:@"dev-perf-monitor"]) {
    id perfMonitor = [self _moduleInstanceForBridge:bridge named:@"PerfMonitor"];
    if (perfMonitor) {
      if (devSettings.isPerfMonitorShown) {
        [perfMonitor hide];
        devSettings.isPerfMonitorShown = NO;
      } else {
        [perfMonitor show];
        devSettings.isPerfMonitorShown = YES;
      }
    }
  }
}

- (void)showDevMenuForBridge:(id)bridge
{
  RCTAssertMainThread();
  id devMenu = [self _moduleInstanceForBridge:bridge named:@"DevMenu"];
  // respondsToSelector: check is required because it's possible this bridge
  // was instantiated with a `disabledDevMenu` instance and the gesture preference was recently updated.
  if ([devMenu respondsToSelector:@selector(show)]) {
    [((RCTDevMenu *)devMenu) show];
  }
}

- (void)disableRemoteDebuggingForBridge:(id)bridge
{
  RCTDevSettings *devSettings = [self _moduleInstanceForBridge:bridge named:@"DevSettings"];
  devSettings.isDebuggingRemotely = NO;
}

- (void)toggleElementInspectorForBridge:(id)bridge
{
  RCTDevSettings *devSettings = [self _moduleInstanceForBridge:bridge named:@"DevSettings"];
  [devSettings toggleElementInspector];
}


#pragma mark - internal

- (id<RCTBridgeModule>)_moduleInstanceForBridge:(id)bridge named:(NSString *)name
{
  if ([bridge respondsToSelector:@selector(batchedBridge)]) {
    bridge = [bridge batchedBridge];
  }
  RCTModuleData *data = [bridge moduleDataForName:name];
  if (data) {
    return [data instance];
  }
  return nil;
}

- (void)configureABIWithFatalHandler:(void (^)(NSError *))fatalHandler
                         logFunction:(void (^)(NSInteger, NSInteger, NSString *, NSNumber *, NSString *))logFunction
                        logThreshold:(NSInteger)threshold
{
  if (EXVersionManagerIsFirstLoad == nil) {
    // first time initializing this RN version at runtime
    _isFirstLoad = YES;
  }
  EXVersionManagerIsFirstLoad = @(NO);
  RCTSetFatalHandler(fatalHandler);
  RCTSetLogThreshold(threshold);
  RCTSetLogFunction(logFunction);
}

/**
 *  Expected params:
 *    NSDictionary *manifest
 *    NSDictionary *constants
 *    NSURL *initialUri
 *    @BOOL isDeveloper
 *    @BOOL isStandardDevMenuAllowed
 *    @BOOL isTestEnvironment
 *    NSDictionary *services
 *
 * Kernel-only:
 *    EXKernel *kernel
 *    NSArray *supportedSdkVersions
 *    id exceptionsManagerDelegate
 *
 * Frame-only:
 *    EXFrame *frame
 */
- (NSArray *)extraModulesWithParams:(NSDictionary *)params
{
  BOOL isDeveloper = [params[@"isDeveloper"] boolValue];
  NSDictionary *manifest = params[@"manifest"];
  NSString *experienceId = manifest[@"id"];
  NSDictionary *services = params[@"services"];
  NSString *localStorageDirectory = [[EXFileSystem documentDirectoryForExperienceId:experienceId] stringByAppendingPathComponent:EX_UNVERSIONED(@"RCTAsyncLocalStorage")];

  NSMutableArray *extraModules = [NSMutableArray arrayWithArray:
                                  @[
                                    [[EXAppState alloc] init],
                                    [[EXDevSettings alloc] initWithExperienceId:experienceId isDevelopment:isDeveloper],
                                    [[EXDisabledDevLoadingView alloc] init],
                                    [[EXStatusBarManager alloc] init],
                                    [[RCTAsyncLocalStorage alloc] initWithStorageDirectory:localStorageDirectory],
                                    ]];
  
  // add scoped modules
  [extraModules addObjectsFromArray:[self _newScopedModulesWithExperienceId:experienceId services:services params:params]];
  
  if (params[@"frame"]) {
    [extraModules addObject:[[EXFrameExceptionsManager alloc] initWithDelegate:params[@"frame"]]];
  } else {
    id exceptionsManagerDelegate = params[@"exceptionsManagerDelegate"];
    if (exceptionsManagerDelegate) {
      RCTExceptionsManager *exceptionsManager = [[RCTExceptionsManager alloc] initWithDelegate:exceptionsManagerDelegate];
      [extraModules addObject:exceptionsManager];
    } else {
      RCTLogWarn(@"No exceptions manager provided when building extra modules for bridge.");
    }
  }
  
  if (params[@"isTestEnvironment"]) {
    EXTest *testModule = [[EXTest alloc] init];
    [extraModules addObject:testModule];
  }
  
  if (params[@"kernel"]) {
    EXKernelModule *kernel = [[EXKernelModule alloc] initWithExperienceId:experienceId
                                                    kernelServiceDelegate:services[EX_UNVERSIONED(@"EXKernelModuleManager")]
                                                                   params:params];
    [extraModules addObject:kernel];
  }

  if ([params[@"isStandardDevMenuAllowed"] boolValue] && isDeveloper) {
    [extraModules addObject:[[RCTDevMenu alloc] init]];
  } else {
    // non-kernel, or non-development kernel, uses expo menu instead of RCTDevMenu
    [extraModules addObject:[[EXDisabledDevMenu alloc] init]];
  }
  if (!isDeveloper) {
    // user-facing (not debugging).
    // additionally disable RCTRedBox
    [extraModules addObject:[[EXDisabledRedBox alloc] init]];
  }
  return extraModules;
}

- (NSArray *)_newScopedModulesWithExperienceId: (NSString *)experienceId services:(NSDictionary *)services params:(NSDictionary *)params
{
  NSMutableArray *result = [NSMutableArray array];
  if (EXScopedModuleClasses) {
    [EXScopedModuleClasses enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull scopedModuleClassName, NSString * _Nonnull kernelServiceClassName, BOOL * _Nonnull stop) {
      id service = ([kernelServiceClassName isEqualToString:EX_KERNEL_SERVICE_NONE]) ? nil : services[kernelServiceClassName];
      Class scopedModuleClass = NSClassFromString(scopedModuleClassName);
      id scopedModule = [[scopedModuleClass alloc] initWithExperienceId:experienceId kernelServiceDelegate:service params:params];
      if (scopedModule) {
        [result addObject:scopedModule];
      }
    }];
  }
  return result;
}

@end
