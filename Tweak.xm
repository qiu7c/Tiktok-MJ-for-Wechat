#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Sources/MJRenderer.h"

@interface WCPluginsMgr : NSObject
+ (instancetype)sharedInstance;
- (void)registerSwitchWithTitle:(NSString *)title key:(NSString *)key;
@end

@interface CMessageWrap : NSObject
@end

static char MJIncomingCheckPendingKey;
static char MJOutgoingTimestampKey;
static BOOL MJLastEnabledState;
static UIAlertController *MJAssetInitializationAlert;
static NSMutableDictionary<NSString *, NSNumber *> *MJPendingIncoming;
static NSMutableDictionary<NSString *, NSNumber *> *MJConsumedIncoming;
static NSLock *MJIncomingLock;
static NSHashTable<UIView *> *MJVisibleMessageCells;

static id MJValue(id object, NSString *key);
static NSString *MJString(id value);

static UIViewController *MJTopViewController(void) {
    UIWindow *window = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    if (!window) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            for (UIWindow *candidate in scene.windows) {
                if (!candidate.hidden && candidate.alpha > 0.0 && candidate.windowLevel == UIWindowLevelNormal) {
                    window = candidate;
                    break;
                }
            }
            if (window) break;
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    while ([controller isKindOfClass:UINavigationController.class] && ((UINavigationController *)controller).visibleViewController) {
        controller = ((UINavigationController *)controller).visibleViewController;
    }
    while ([controller isKindOfClass:UITabBarController.class] && ((UITabBarController *)controller).selectedViewController) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

static void MJShowAuthorPrompt(void) {
    UIViewController *presenter = MJTopViewController();
    if (!presenter || presenter.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MJ 彩蛋"
                                                                     message:@"作者：qiu7c\n如若要卸载插件，请先将插件开关关闭并选择清除缓存，清除后再移除本插件。\n喜欢的话，欢迎给仓库点个 Star。"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"暂不前往" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"前往 GitHub" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSURL *URL = [NSURL URLWithString:@"https://github.com/qiu7c/Tiktok-MJ-for-Wechat"];
        if (URL) [UIApplication.sharedApplication openURL:URL options:@{} completionHandler:nil];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void MJBeginAssetInitialization(void) {
    if (MJAssetInitializationAlert) return;
    if (MJAlphaAssetsReady()) {
        MJShowAuthorPrompt();
        return;
    }
    UIViewController *presenter = MJTopViewController();
    if (!presenter || presenter.presentedViewController) return;
    MJAssetInitializationAlert = [UIAlertController alertControllerWithTitle:@"MJ 彩蛋"
                                                                         message:@"正在初始化动画素材…\n首次初始化需要下载动画文件，完成时间取决于网络速度。建议关闭代理/VPN 并保持微信开启，完成前无法启用彩蛋。"
                                                                  preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:MJAssetInitializationAlert animated:YES completion:nil];
    MJEnsureAssetsReady(^(BOOL success, NSString *errorMessage) {
        UIAlertController *alert = MJAssetInitializationAlert;
        if (success) {
            MJAssetInitializationAlert = nil;
            [alert dismissViewControllerAnimated:YES completion:^{ MJShowAuthorPrompt(); }];
            return;
        }
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:MJEnabledKey];
        MJLastEnabledState = NO;
        alert.message = [NSString stringWithFormat:@"动画素材初始化失败，彩蛋已关闭。\n%@\n请检查网络后重试。",
                         errorMessage.length > 0 ? errorMessage : @"未知错误"];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            MJAssetInitializationAlert = nil;
        }]];
    });
}

static void MJConfirmAssetRemoval(void) {
    UIViewController *presenter = MJTopViewController();
    if (!presenter || presenter.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MJ 彩蛋"
                                                                     message:@"是否删除已下载的本地动画素材？保留后下次开启可立即播放。"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"保留素材" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除素材" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        MJDeleteLocalAssets();
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void MJInstallEnablePrompt(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    MJLastEnabledState = [defaults boolForKey:MJEnabledKey];
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:defaults
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification *note) {
        BOOL enabled = [defaults boolForKey:MJEnabledKey];
        if (enabled && !MJLastEnabledState) MJBeginAssetInitialization();
        if (!enabled && MJLastEnabledState) MJConfirmAssetRemoval();
        MJLastEnabledState = enabled;
    }];
    if (MJLastEnabledState && !MJAlphaAssetsReady()) MJBeginAssetInitialization();
}

static id MJValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *MJString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSString *MJCurrentUser(void) {
    Class centerClass = NSClassFromString(@"MMServiceCenter");
    Class contactClass = NSClassFromString(@"CContactMgr");
    SEL defaultSelector = NSSelectorFromString(@"defaultCenter");
    SEL serviceSelector = NSSelectorFromString(@"getService:");
    SEL selfSelector = NSSelectorFromString(@"getSelfContact");
    if (!centerClass || !contactClass || ![centerClass respondsToSelector:defaultSelector]) return nil;
    id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, defaultSelector);
    if (!center || ![center respondsToSelector:serviceSelector]) return nil;
    id manager = ((id (*)(id, SEL, Class))objc_msgSend)(center, serviceSelector, contactClass);
    if (!manager || ![manager respondsToSelector:selfSelector]) return nil;
    id contact = ((id (*)(id, SEL))objc_msgSend)(manager, selfSelector);
    for (NSString *key in @[@"m_nsUsr", @"m_nsUserName", @"username", @"userName"]) {
        NSString *value = MJString(MJValue(contact, key));
        if (value.length > 0) return value;
    }
    return nil;
}

static NSString *MJTextFromWrap(id wrap) {
    NSString *text = MJString(MJValue(wrap, @"m_nsContent"));
    if (text.length == 0) return @"";
    NSRange separator = [text rangeOfString:@":\n"];
    if (separator.location != NSNotFound && separator.location < 96) {
        NSString *prefix = [text substringToIndex:separator.location];
        if ([prefix hasPrefix:@"wxid_"] || [prefix containsString:@"@"] || prefix.length >= 5) {
            text = [text substringFromIndex:NSMaxRange(separator)];
        }
    }
    return text;
}

static BOOL MJMatches(id object) {
    NSString *text = [object isKindOfClass:NSString.class] ? object : MJTextFromWrap(object);
    if (text.length < 2 || text.length % 2 != 0) return NO;
    for (NSUInteger index = 0; index < text.length; index += 2) {
        if ([[text substringWithRange:NSMakeRange(index, 2)] caseInsensitiveCompare:@"mj"] != NSOrderedSame) return NO;
    }
    return YES;
}

static BOOL MJIncomingWrap(id wrap) {
    NSString *current = MJCurrentUser();
    NSString *from = MJString(MJValue(wrap, @"m_nsFromUsr"));
    NSString *real = MJString(MJValue(wrap, @"m_nsRealChatUsr"));
    if (current.length == 0 || (from.length == 0 && real.length == 0)) return NO;
    return ![from isEqualToString:current] && ![real isEqualToString:current];
}

static NSArray<NSString *> *MJMessageIdentities(id wrap) {
    if (!wrap) return @[];
    NSMutableOrderedSet<NSString *> *identities = [NSMutableOrderedSet orderedSet];
    SEL combinedSelector = NSSelectorFromString(@"combineChatNameWithLocalId");
    if ([wrap respondsToSelector:combinedSelector]) {
        id combined = ((id (*)(id, SEL))objc_msgSend)(wrap, combinedSelector);
        if ([combined isKindOfClass:NSString.class] && [combined length] > 0) {
            [identities addObject:[@"combined:" stringByAppendingString:combined]];
        }
    }

    NSString *chatName = nil;
    SEL chatSelector = NSSelectorFromString(@"GetChatName");
    if ([wrap respondsToSelector:chatSelector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(wrap, chatSelector);
        if ([value isKindOfClass:NSString.class]) chatName = value;
    }
    unsigned long long localID = [MJValue(wrap, @"m_uiMesLocalID") unsignedLongLongValue];
    long long serverID = [MJValue(wrap, @"m_n64MesSvrID") longLongValue];
    if (chatName.length > 0 && localID > 0) {
        [identities addObject:[NSString stringWithFormat:@"local:%@:%llu", chatName, localID]];
    }
    if (chatName.length > 0 && serverID != 0) {
        [identities addObject:[NSString stringWithFormat:@"server:%@:%lld", chatName, serverID]];
    }
    return identities.array;
}

static void MJPruneIncomingLocked(NSTimeInterval now) {
    const NSTimeInterval pendingTTL = 600.0;
    const NSTimeInterval consumedTTL = 600.0;
    for (NSString *key in MJPendingIncoming.allKeys) {
        if (now - MJPendingIncoming[key].doubleValue > pendingTTL) [MJPendingIncoming removeObjectForKey:key];
    }
    for (NSString *key in MJConsumedIncoming.allKeys) {
        if (now - MJConsumedIncoming[key].doubleValue > consumedTTL) [MJConsumedIncoming removeObjectForKey:key];
    }
    const NSUInteger maximumPendingIdentities = 384;
    if (MJPendingIncoming.count > maximumPendingIdentities) {
        NSArray<NSString *> *oldestFirst = [MJPendingIncoming keysSortedByValueUsingSelector:@selector(compare:)];
        NSUInteger excess = MJPendingIncoming.count - maximumPendingIdentities;
        for (NSUInteger index = 0; index < excess; index++) {
            [MJPendingIncoming removeObjectForKey:oldestFirst[index]];
        }
    }
}

static void MJRegisterIncoming(id wrap) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:MJEnabledKey] ||
        [MJValue(wrap, @"m_uiMessageType") integerValue] != 1 ||
        !MJIncomingWrap(wrap) || !MJMatches(wrap)) return;
    NSArray<NSString *> *identities = MJMessageIdentities(wrap);
    if (identities.count == 0) return;

    [MJIncomingLock lock];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    MJPruneIncomingLocked(now);
    for (NSString *identity in identities) {
        if (MJConsumedIncoming[identity]) {
            [MJIncomingLock unlock];
            return;
        }
    }
    for (NSString *identity in identities) MJPendingIncoming[identity] = @(now);
    [MJIncomingLock unlock];
}

static BOOL MJConsumeIncoming(id wrap) {
    NSArray<NSString *> *identities = MJMessageIdentities(wrap);
    if (identities.count == 0 || !MJIncomingLock) return NO;
    [MJIncomingLock lock];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    MJPruneIncomingLocked(now);
    BOOL pending = NO;
    for (NSString *identity in identities) {
        if (MJPendingIncoming[identity]) { pending = YES; break; }
    }
    if (pending) {
        for (NSString *identity in identities) {
            [MJPendingIncoming removeObjectForKey:identity];
            MJConsumedIncoming[identity] = @(now);
        }
    }
    [MJIncomingLock unlock];
    return pending;
}

static void MJTriggerOutgoing(id sender, id text) {
    if (!MJMatches(text) || ![NSUserDefaults.standardUserDefaults boolForKey:MJEnabledKey]) return;
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *previous = objc_getAssociatedObject(sender, &MJOutgoingTimestampKey);
    if (previous && now - previous.doubleValue < 0.5) return;
    objc_setAssociatedObject(sender, &MJOutgoingTimestampKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MJPlayEasterEgg();
}

static id MJMessageWrapForCell(id cell) {
    id viewModel = MJValue(cell, @"viewModel") ?: MJValue(cell, @"m_viewModel");
    id wrap = MJValue(viewModel, @"messageWrap") ?: MJValue(viewModel, @"m_messageWrap") ?:
              MJValue(viewModel, @"msgWrap") ?: MJValue(viewModel, @"wrap");
    if (wrap) return wrap;
    id parentModel = MJValue(viewModel, @"parentModel");
    return MJValue(parentModel, @"messageWrap") ?: MJValue(parentModel, @"m_messageWrap") ?:
           MJValue(parentModel, @"msgWrap") ?: MJValue(parentModel, @"wrap");
}

static BOOL MJCellIsVisibleInForeground(UIView *cell) {
    UIWindow *window = cell.window;
    UIApplication *application = UIApplication.sharedApplication;
    if (!window || window.hidden || window.alpha <= 0.0 ||
        application.applicationState != UIApplicationStateActive ||
        (window.windowScene && window.windowScene.activationState != UISceneActivationStateForegroundActive)) {
        return NO;
    }
    for (UIView *view = cell; view; view = view.superview) {
        if (view.hidden || view.alpha <= 0.0) return NO;
    }
    CGRect visibleRect = [cell convertRect:cell.bounds toView:window];
    for (UIView *view = cell; view; view = view.superview) {
        if (view.clipsToBounds) {
            visibleRect = CGRectIntersection(visibleRect, [view convertRect:view.bounds toView:window]);
            if (CGRectIsEmpty(visibleRect)) return NO;
        }
    }
    return CGRectIntersectsRect(visibleRect, window.bounds);
}

static void MJCheckIncomingCell(UIView *cell) {
    if (!MJCellIsVisibleInForeground(cell) ||
        ![NSUserDefaults.standardUserDefaults boolForKey:MJEnabledKey]) return;
    id wrap = MJMessageWrapForCell(cell);
    if ([MJValue(wrap, @"m_uiMessageType") integerValue] != 1 ||
        !MJIncomingWrap(wrap) || !MJMatches(wrap)) return;
    if (MJConsumeIncoming(wrap)) MJPlayEasterEgg();
}

static void MJScheduleIncomingCellCheck(UIView *cell) {
    if (!cell || [objc_getAssociatedObject(cell, &MJIncomingCheckPendingKey) boolValue]) return;
    objc_setAssociatedObject(cell, &MJIncomingCheckPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakCell = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongCell = weakCell;
        if (!strongCell) return;
        if (strongCell.window) [MJVisibleMessageCells addObject:strongCell];
        MJCheckIncomingCell(strongCell);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *delayedCell = weakCell;
            if (!delayedCell) return;
            objc_setAssociatedObject(delayedCell, &MJIncomingCheckPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            MJCheckIncomingCell(delayedCell);
        });
    });
}

%hook BaseMsgContentLogicController
- (void)SendTextMessage:(id)text {
    %orig(text);
    MJTriggerOutgoing(self, text);
}
- (void)SendTextMessage:(id)text replyingMessage:(id)replyingMessage isPasted:(BOOL)isPasted {
    %orig(text, replyingMessage, isPasted);
    MJTriggerOutgoing(self, text);
}
%end

%hook CMessageMgr
- (void)AddMsg:(NSString *)target MsgWrap:(CMessageWrap *)wrap {
    MJRegisterIncoming(wrap);
    %orig(target, wrap);
}
- (void)onNewSyncAddMessage:(id)wrap {
    MJRegisterIncoming(wrap);
    %orig(wrap);
}
- (void)AsyncOnPreAddMsg:(id)first MsgWrap:(id)second {
    MJRegisterIncoming(second ?: first);
    %orig(first, second);
}
- (void)AsyncOnAddMsg:(id)first MsgWrap:(id)second {
    MJRegisterIncoming(second ?: first);
    %orig(first, second);
}
- (void)AsyncOnAddMsgForSession:(id)session MsgWrap:(id)wrap {
    MJRegisterIncoming(wrap ?: session);
    %orig(session, wrap);
}
- (void)AsyncOnAddMsgForSession:(id)session MsgWrap:(id)wrap NewMsgArriveNotify:(BOOL)notify {
    MJRegisterIncoming(wrap ?: session);
    %orig(session, wrap, notify);
}
%end

%hook CommonMessageCellView
- (void)setViewModel:(id)viewModel {
    %orig(viewModel);
    MJScheduleIncomingCellCheck((UIView *)self);
}
- (void)updateStatus {
    %orig;
    MJScheduleIncomingCellCheck((UIView *)self);
}
- (void)updateNodeStatus {
    %orig;
    MJScheduleIncomingCellCheck((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    UIView *cell = (UIView *)self;
    if (cell.window) MJScheduleIncomingCellCheck(cell);
    else [MJVisibleMessageCells removeObject:cell];
}
%end

%ctor {
    MJIncomingLock = [NSLock new];
    MJPendingIncoming = [NSMutableDictionary dictionary];
    MJConsumedIncoming = [NSMutableDictionary dictionary];
    MJVisibleMessageCells = [NSHashTable weakObjectsHashTable];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{MJEnabledKey: @YES}];
        MJInstallEnablePrompt();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                           object:nil
                                                            queue:NSOperationQueue.mainQueue
                                                       usingBlock:^(__unused NSNotification *note) {
            for (UIView *cell in MJVisibleMessageCells.allObjects) {
                MJScheduleIncomingCellCheck(cell);
            }
        }];
        Class managerClass = NSClassFromString(@"WCPluginsMgr");
        if (managerClass && [managerClass respondsToSelector:@selector(sharedInstance)]) {
            WCPluginsMgr *manager = [managerClass sharedInstance];
            [manager registerSwitchWithTitle:@"MJ 彩蛋" key:MJEnabledKey];
        }
    });
}
