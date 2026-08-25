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

static char MJIncomingHandledKey;
static char MJOutgoingTimestampKey;
static char MJAuthorSearchLogicKey;
static BOOL MJLastEnabledState;
static UIAlertController *MJAssetInitializationAlert;
static NSMutableDictionary<NSString *, NSMutableArray *> *MJPendingIncoming;
static NSLock *MJPendingIncomingLock;

static id MJValue(id object, NSString *key);
static NSString *MJString(id value);
static id MJServiceForClass(Class serviceClass);

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
    while (controller) {
        UIViewController *next = nil;
        if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
            next = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)controller).selectedViewController;
        }
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static NSString *MJControllerChatUser(UIViewController *controller) {
    if (!controller) return nil;
    NSString *className = NSStringFromClass(controller.class).lowercaseString;
    if (![className containsString:@"msgcontent"] &&
        ![className containsString:@"chatroom"] &&
        ![className containsString:@"messagecontent"]) return nil;
    for (NSString *key in @[@"m_nsUsr", @"m_nsUserName", @"m_nsToUsr", @"m_nsChatRoomUsr", @"m_chatRoomUsr", @"username", @"userName"]) {
        NSString *value = MJString(MJValue(controller, key));
        if (value.length > 0) return value;
    }
    for (NSString *key in @[@"m_contact", @"contact", @"m_chatContact"]) {
        id contact = MJValue(controller, key);
        for (NSString *contactKey in @[@"m_nsUsr", @"m_nsUserName", @"username", @"userName"]) {
            NSString *value = MJString(MJValue(contact, contactKey));
            if (value.length > 0) return value;
        }
    }
    return nil;
}

static BOOL MJIsChatPageVisible(void) {
    UIViewController *controller = MJTopViewController();
    if (!controller) return NO;
    NSString *className = NSStringFromClass(controller.class).lowercaseString;
    return [className containsString:@"msgcontent"] ||
           [className containsString:@"chatroom"] ||
           [className containsString:@"messagecontent"];
}

static void MJOpenAuthorProfile(UIViewController *sourceController) {
    NSString *userName = @"ic7ouo";
    Class handlerClass = NSClassFromString(@"MMURLHandler");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    SEL constructSelector = NSSelectorFromString(@"constructContactInfoView:withUserName:");
    id handler = handlerClass && [handlerClass respondsToSelector:sharedSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(handlerClass, sharedSelector) : nil;
    id contactManager = MJServiceForClass(NSClassFromString(@"CContactMgr"));
    id contact = nil;
    for (NSString *selectorName in @[@"getContactByName:", @"getContactByNameFromCache:"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (!contactManager || ![contactManager respondsToSelector:selector]) continue;
        contact = ((id (*)(id, SEL, id))objc_msgSend)(contactManager, selector, userName);
        if (contact) break;
    }
    if (handler && contact && [handler respondsToSelector:constructSelector]) {
        id profileController = ((id (*)(id, SEL, id, id))objc_msgSend)(handler,
                                                                       constructSelector,
                                                                       contact,
                                                                       userName);
        if ([profileController isKindOfClass:UIViewController.class] && sourceController.navigationController) {
            [sourceController.navigationController pushViewController:profileController animated:YES];
            return;
        }
    }
    Class searchClass = NSClassFromString(@"GetA8KeyLogic");
    SEL initializer = NSSelectorFromString(@"initWithViewController:delegate:");
    SEL searchSelector = NSSelectorFromString(@"doSearchContact:FromScene:SearchScene:picUrl:");
    id searchLogic = searchClass && [searchClass instancesRespondToSelector:initializer]
        ? ((id (*)(id, SEL, id, id))objc_msgSend)([searchClass alloc], initializer, sourceController, nil)
        : nil;
    if (searchLogic && [searchLogic respondsToSelector:searchSelector]) {
        objc_setAssociatedObject(sourceController, &MJAuthorSearchLogicKey,
                                 searchLogic, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, id, NSUInteger, NSUInteger, id))objc_msgSend)(searchLogic,
                                                                          searchSelector,
                                                                          userName,
                                                                          0,
                                                                          0,
                                                                          nil);
        return;
    }
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"weixin://contacts/profile/%@", userName]];
    if (URL && [UIApplication.sharedApplication canOpenURL:URL]) {
        [UIApplication.sharedApplication openURL:URL options:@{} completionHandler:nil];
        return;
    }
    UIPasteboard.generalPasteboard.string = userName;
}

static void MJShowAuthorPrompt(void) {
    UIViewController *presenter = MJTopViewController();
    if (!presenter || presenter.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MJ 彩蛋"
                                                                     message:@"作者：qiu7c\n如若要卸载插件，请先将插件开关关闭并选择清除缓存，清除后再移除本插件。\n喜欢的话，欢迎给仓库点个 Star。"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"暂不前往" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"作者主页" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        MJOpenAuthorProfile(presenter);
    }]];
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

static id MJServiceForClass(Class serviceClass) {
    Class centerClass = NSClassFromString(@"MMServiceCenter");
    SEL defaultSelector = NSSelectorFromString(@"defaultCenter");
    SEL serviceSelector = NSSelectorFromString(@"getService:");
    if (!centerClass || !serviceClass || ![centerClass respondsToSelector:defaultSelector]) return nil;
    id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, defaultSelector);
    if (!center || ![center respondsToSelector:serviceSelector]) return nil;
    return ((id (*)(id, SEL, Class))objc_msgSend)(center, serviceSelector, serviceClass);
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
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL MJMatches(id object) {
    NSString *text = [object isKindOfClass:NSString.class] ? object : MJTextFromWrap(object);
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
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
    NSString *to = MJString(MJValue(wrap, @"m_nsToUsr"));
    NSString *chatRoom = MJString(MJValue(wrap, @"m_nsChatRoomUsr"));
    if (current.length == 0) return NO;
    BOOL group = [from containsString:@"@chatroom"] ||
                 [to containsString:@"@chatroom"] ||
                 [chatRoom containsString:@"@chatroom"];
    NSString *sender = group ? real : from;
    if (sender.length == 0 && ![from containsString:@"@chatroom"]) sender = from;
    return sender.length > 0 && ![sender isEqualToString:current];
}

static void MJQueueIncoming(NSString *target, id wrap) {
    if (target.length == 0 || !wrap) return;
    if (!MJPendingIncoming) MJPendingIncoming = [NSMutableDictionary dictionary];
    if (!MJPendingIncomingLock) MJPendingIncomingLock = [NSLock new];
    [MJPendingIncomingLock lock];
    NSMutableArray *items = MJPendingIncoming[target];
    if (!items) {
        items = [NSMutableArray array];
        MJPendingIncoming[target] = items;
    }
    if (![items containsObject:wrap]) [items addObject:wrap];
    [MJPendingIncomingLock unlock];
}

static void MJDrainIncomingForChat(NSString *target) {
    if (target.length == 0 || !MJPendingIncomingLock) return;
    [MJPendingIncomingLock lock];
    NSArray *items = [MJPendingIncoming[target] copy];
    [MJPendingIncoming removeObjectForKey:target];
    [MJPendingIncomingLock unlock];
    for (id wrap in items) {
        if (![objc_getAssociatedObject(wrap, &MJIncomingHandledKey) boolValue]) {
            objc_setAssociatedObject(wrap, &MJIncomingHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            MJPlayEasterEgg();
        }
    }
}

static void MJTriggerOutgoing(id sender, id text) {
    if (!MJMatches(text) || ![NSUserDefaults.standardUserDefaults boolForKey:MJEnabledKey]) return;
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *previous = objc_getAssociatedObject(sender, &MJOutgoingTimestampKey);
    if (previous && now - previous.doubleValue < 0.5) return;
    objc_setAssociatedObject(sender, &MJOutgoingTimestampKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MJPlayEasterEgg();
}

static void MJTriggerIncoming(id wrap) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:MJEnabledKey] || !wrap ||
        [objc_getAssociatedObject(wrap, &MJIncomingHandledKey) boolValue]) return;
    if ([MJValue(wrap, @"m_uiMessageType") integerValue] != 1 || !MJIncomingWrap(wrap) || !MJMatches(wrap)) return;
    objc_setAssociatedObject(wrap, &MJIncomingHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MJPlayEasterEgg();
}

static NSString *MJIncomingChatCandidate(NSString *target, id wrap, NSString *visibleChat) {
    NSArray *candidates = @[MJString(MJValue(wrap, @"m_nsFromUsr")) ?: @"",
                            MJString(MJValue(wrap, @"m_nsChatRoomUsr")) ?: @"",
                            target ?: @"",
                            MJString(MJValue(wrap, @"m_nsRealChatUsr")) ?: @"",
                            MJString(MJValue(wrap, @"m_nsToUsr")) ?: @""];
    for (NSString *candidate in candidates) {
        if (candidate.length > 0 && [candidate isEqualToString:visibleChat]) return candidate;
    }
    NSString *current = MJCurrentUser();
    for (NSString *candidate in candidates) {
        if (candidate.length > 0 && ![candidate isEqualToString:current]) return candidate;
    }
    return nil;
}

static BOOL MJIncomingMatchesVisibleChat(NSString *target, id wrap, NSString *visibleChat) {
    if (visibleChat.length == 0) return NO;
    NSArray *candidates = @[target ?: @"",
                            MJString(MJValue(wrap, @"m_nsFromUsr")) ?: @"",
                            MJString(MJValue(wrap, @"m_nsRealChatUsr")) ?: @"",
                            MJString(MJValue(wrap, @"m_nsToUsr")) ?: @"",
                            MJString(MJValue(wrap, @"m_nsChatRoomUsr")) ?: @""];
    return [candidates containsObject:visibleChat];
}

static BOOL MJVisibleCellContainsWrap(UIView *view, id wrap) {
    if (!view || !wrap) return NO;
    if ([view isKindOfClass:UITableViewCell.class] || [view isKindOfClass:UICollectionViewCell.class]) {
        for (NSString *key in @[@"m_msgWrap", @"m_messageWrap", @"msgWrap", @"messageWrap", @"m_wrap", @"wrap", @"m_msg", @"m_message", @"m_msgData", @"msgData", @"message", @"m_messageData", @"m_cellData", @"m_data"]) {
            id value = MJValue(view, key);
            if (value == wrap || MJValue(value, @"m_msgWrap") == wrap || MJValue(value, @"messageWrap") == wrap) return YES;
        }
    }
    for (UIView *subview in view.subviews) {
        if (MJVisibleCellContainsWrap(subview, wrap)) return YES;
    }
    return NO;
}

static BOOL MJVisibleCellContainsText(UIView *view, NSString *text) {
    if (!view || text.length == 0 || view.hidden || view.alpha <= 0.01) return NO;
    if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:text]) return YES;
    if ([view isKindOfClass:UITextView.class] && [((UITextView *)view).text isEqualToString:text]) return YES;
    for (UIView *subview in view.subviews) {
        if (MJVisibleCellContainsText(subview, text)) return YES;
    }
    return NO;
}

static BOOL MJVisibleCellContainsMessage(UIView *cell, id wrap) {
    if (MJVisibleCellContainsWrap(cell, wrap)) return YES;
    return MJVisibleCellContainsText(cell, MJTextFromWrap(wrap));
}

static BOOL MJViewTreeContainsWrap(UIView *view, id wrap) {
    if (!view || !wrap) return NO;
    if ([view isKindOfClass:UITableView.class]) {
        for (UITableViewCell *cell in ((UITableView *)view).visibleCells) {
            if (MJVisibleCellContainsMessage(cell, wrap)) return YES;
        }
        return NO;
    }
    if ([view isKindOfClass:UICollectionView.class]) {
        for (UICollectionViewCell *cell in ((UICollectionView *)view).visibleCells) {
            if (MJVisibleCellContainsMessage(cell, wrap)) return YES;
        }
        return NO;
    }
    for (UIView *subview in view.subviews) {
        if (MJViewTreeContainsWrap(subview, wrap)) return YES;
    }
    return NO;
}

static BOOL MJVisiblePageContainsWrap(id wrap) {
    if (!MJIsChatPageVisible() || !wrap) return NO;
    UIViewController *controller = MJTopViewController();
    return MJViewTreeContainsWrap(controller.view, wrap);
}

static void MJDrainVisibleIncoming(void) {
    if (!MJPendingIncomingLock || !MJIsChatPageVisible()) return;
    [MJPendingIncomingLock lock];
    NSDictionary *snapshot = [MJPendingIncoming copy];
    [MJPendingIncomingLock unlock];
    [snapshot enumerateKeysAndObjectsUsingBlock:^(NSString *chat, NSArray *items, __unused BOOL *stop) {
        for (id wrap in items) {
            if (!MJVisiblePageContainsWrap(wrap)) continue;
            [MJPendingIncomingLock lock];
            NSMutableArray *pending = MJPendingIncoming[chat];
            [pending removeObject:wrap];
            if (pending.count == 0) [MJPendingIncoming removeObjectForKey:chat];
            [MJPendingIncomingLock unlock];
            MJTriggerIncoming(wrap);
        }
    }];
}

static void MJWaitForVisibleIncoming(id wrap, NSString *chat, NSUInteger attempt) {
    if (!wrap || !MJIsChatPageVisible()) return;
    if (MJVisiblePageContainsWrap(wrap)) {
        MJTriggerIncoming(wrap);
        return;
    }
    if (attempt >= 8) {
        MJQueueIncoming(chat, wrap);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MJWaitForVisibleIncoming(wrap, chat, attempt + 1);
    });
}

static void MJScheduleIncoming(NSString *target, id wrap) {
    if (!wrap || [MJValue(wrap, @"m_uiMessageType") integerValue] != 1 ||
        !MJIncomingWrap(wrap) || !MJMatches(wrap)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *visibleChat = MJControllerChatUser(MJTopViewController());
        NSString *chat = MJIncomingChatCandidate(target, wrap, visibleChat);
        BOOL sameChat = MJIncomingMatchesVisibleChat(target, wrap, visibleChat);
        if (sameChat) MJTriggerIncoming(wrap);
        else if (MJIsChatPageVisible()) MJWaitForVisibleIncoming(wrap, chat, 0);
        else MJQueueIncoming(chat, wrap);
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
    %orig(target, wrap);
    MJScheduleIncoming(target, wrap);
}
- (void)onNewSyncAddMessage:(id)wrap {
    %orig(wrap);
    MJScheduleIncoming(nil, wrap);
}
- (void)AsyncOnPreAddMsg:(id)first MsgWrap:(id)second {
    %orig(first, second);
    MJScheduleIncoming(nil, second ?: first);
}
- (void)AsyncOnAddMsg:(id)first MsgWrap:(id)second {
    %orig(first, second);
    MJScheduleIncoming(nil, second ?: first);
}
- (void)AsyncOnAddMsgForSession:(id)session MsgWrap:(id)wrap {
    %orig(session, wrap);
    MJScheduleIncoming(nil, wrap ?: session);
}
- (void)AsyncOnAddMsgForSession:(id)session MsgWrap:(id)wrap NewMsgArriveNotify:(BOOL)notify {
    %orig(session, wrap, notify);
    MJScheduleIncoming(nil, wrap ?: session);
}
%end

%hook BaseMsgContentViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    NSString *chat = MJControllerChatUser((UIViewController *)self);
    if (chat.length > 0) MJDrainIncomingForChat(chat);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ MJDrainVisibleIncoming(); });
}
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{MJEnabledKey: @YES}];
        MJInstallEnablePrompt();
        Class managerClass = NSClassFromString(@"WCPluginsMgr");
        if (managerClass && [managerClass respondsToSelector:@selector(sharedInstance)]) {
            WCPluginsMgr *manager = [managerClass sharedInstance];
            [manager registerSwitchWithTitle:@"MJ 彩蛋" key:MJEnabledKey];
        }
    });
}
