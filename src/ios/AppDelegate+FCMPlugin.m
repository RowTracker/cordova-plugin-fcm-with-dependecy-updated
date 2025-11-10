#import "AppDelegate+FCMPlugin.h"
#import "FCMPlugin.h"
#import "FCMPluginIOS9Support.h"
#import "FCMNotificationCenterDelegate.h"
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

@import UserNotifications;
@import FirebaseCore;
@import FirebaseMessaging;


// Implement UNUserNotificationCenterDelegate to receive display notification via APNS for devices
// running iOS 10 and above. Implement FIRMessagingDelegate to receive data message via FCM for
// devices running iOS 10 and above.
@interface AppDelegate () <FIRMessagingDelegate>
@end

@implementation AppDelegate (MCPlugin)

static NSData *lastPush;
static NSData *initialPushPayload;
static NSString *fcmToken;
static NSString *apnsToken;
NSString *const kGCMMessageIDKey = @"gcm.message_id";
FCMNotificationCenterDelegate *notificationCenterDelegate;

//Method swizzling
+ (void)load {
    NSLog(@"FCM: Load");

    Method original =  class_getInstanceMethod(self, @selector(application:didFinishLaunchingWithOptions:));
    Method custom =    class_getInstanceMethod(self, @selector(application:customDidFinishLaunchingWithOptions:));
    method_exchangeImplementations(original, custom);
}

- (BOOL)application:(UIApplication *)application customDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self application:application customDidFinishLaunchingWithOptions:launchOptions];

    //ATW looks like we wait 0.3 second before invoking configureForDelegate which in turn invokes FIRApp configure
    // but this means no other method can be called in thosse 300ms. Therefore we do the configure here

    [FIRApp configure];
    // For iOS message (sent via FCM)
    [FIRMessaging messaging].delegate = self;

    if([FIRApp defaultApp] == nil) {
        NSLog(@"FCM: FIRApp configure failed to initialise default app");
    }

    NSLog(@"FCM: DidFinishLaunchingWithOptions");
    if ([UNUserNotificationCenter class] != nil) {
        // For iOS 10 display notification (sent via APNS)
        notificationCenterDelegate = [NSClassFromString(@"FCMNotificationCenterDelegate") alloc];
        [notificationCenterDelegate configureForNotifications];
    }

    [self performSelector:@selector(configureForNotifications) withObject:self afterDelay:0.3f];

    return YES;
}

- (void)configureForNotifications {
    if([FIRApp defaultApp] == nil) {
        [FIRApp configure];
    }
    // For iOS message (sent via FCM)
    [FIRMessaging messaging].delegate = self;
}

+ (void)requestPushPermission:(void (^)(BOOL yesOrNo, NSError* _Nullable error))block withOptions:(NSDictionary*)options {
    if ([UNUserNotificationCenter class] == nil) {
        return [FCMPluginIOS9Support requestPushPermission:block withOptions:options];
    }
    UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
        [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:authOptions completionHandler:^(BOOL granted, NSError* _Nullable error) {
        if (granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] registerForRemoteNotifications];
            });
            block(YES, error);
            return;
        }
        NSLog(@"FCM: User Notification permission denied: %@", error.localizedDescription);
        block(NO, error);
    }];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceTokenData {
    [FIRMessaging messaging].APNSToken = deviceTokenData;
    NSString *deviceToken;
    if (@available(iOS 13, *)) {
        deviceToken = [self hexadecimalStringFromData:deviceTokenData];
    } else {
        deviceToken = [[[[deviceTokenData description]
            stringByReplacingOccurrencesOfString:@"<"withString:@""]
            stringByReplacingOccurrencesOfString:@">" withString:@""]
            stringByReplacingOccurrencesOfString:@" " withString:@""];
    }
    apnsToken = deviceToken;
    NSLog(@"FCM: Device APNS Token: %@", deviceToken);
    if (@available(iOS 10, *)) {
        return;
    }
    [FCMPluginIOS9Support application:application didRegisterForRemoteNotificationsWithDeviceToken:deviceTokenData];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotifications:(NSError *)error {
    NSLog(@"FCM: Failed to register for remote notifications: %@", error);
    if (@available(iOS 10, *)) {
        return;
    }
    [FCMPluginIOS9Support application:application didFailToRegisterForRemoteNotifications:error];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
    if (@available(iOS 10, *)) {
        return;
    }
    [FCMPluginIOS9Support application:application didReceiveRemoteNotification:userInfo];
}
#pragma clang diagnostic pop

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    [[FIRMessaging messaging] appDidReceiveMessage:userInfo];

    if (@available(iOS 10, *)) {
        // Print message ID.
        NSLog(@"FCM: Message ID: %@", userInfo[@"gcm.message_id"]);

        // Pring full message.
        NSLog(@"FCM: %@", userInfo);

        // If the app is in the background, keep it for later, in case it's not tapped.
        if(application.applicationState == UIApplicationStateBackground) {
            NSError *error;
            NSDictionary *userInfoMutable = [userInfo mutableCopy];
            [userInfoMutable setValue:@(NO) forKey:@"wasTapped"];
            NSLog(@"FCM: app active");
            lastPush = [NSJSONSerialization dataWithJSONObject:userInfoMutable options:0 error:&error];
            [AppDelegate setInitialPushPayload:lastPush];
        } else if(application.applicationState == UIApplicationStateInactive) {
            NSError *error;
            NSDictionary *userInfoMutable = [userInfo mutableCopy];
            [userInfoMutable setValue:@(YES) forKey:@"wasTapped"];
            NSLog(@"FCM: app opened by user tap");
            lastPush = [NSJSONSerialization dataWithJSONObject:userInfoMutable options:0 error:&error];
            [AppDelegate setInitialPushPayload:lastPush];
        }

        completionHandler(UIBackgroundFetchResultNoData);
        return;
    }

    [FCMPluginIOS9Support application:application didReceiveRemoteNotification:userInfo fetchCompletionHandler:completionHandler];
}
// [END message_handling]

- (void)messaging:(nonnull FIRMessaging *)messaging didReceiveRegistrationToken:(NSString *)deviceToken {
    NSLog(@"FCM: Device FCM Token: %@", deviceToken);
    if(deviceToken == nil) {
        fcmToken = nil;
        [FCMPlugin.fcmPlugin notifyFCMTokenRefresh:nil];
        return;
    }
    // Notify about received token.
    NSDictionary *dataDict = [NSDictionary dictionaryWithObject:deviceToken forKey:@"token"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FCMToken" object:nil userInfo:dataDict];
    fcmToken = deviceToken;
    [FCMPlugin.fcmPlugin notifyFCMTokenRefresh:deviceToken];
    [self connectToFcm];
}

// [BEGIN connect_to_fcm]
- (void)connectToFcm {
    // Won't connect since there is no token
    if (!fcmToken || !apnsToken) { // ATW 23 Jul 2024, as of firebase 10.4 dont use fcmToken until we have the apnsToken
        return;
    }
    [[FIRMessaging messaging] subscribeToTopic:@"ios"];
    [[FIRMessaging messaging] subscribeToTopic:@"all"];
}
// [END connect_to_fcm]

- (void)applicationDidBecomeActive:(UIApplication *)application {
    NSLog(@"FCM: app become active");
    [FCMPlugin.fcmPlugin appEnterForeground];
    [self connectToFcm];
}

// [BEGIN disconnect_from_fcm]
- (void)applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"FCM: app entered background");
    [FCMPlugin.fcmPlugin appEnterBackground];
    NSLog(@"FCM: Disconnected from FCM");
}
// [END disconnect_from_fcm]

+ (void)setLastPush:(NSData*)push {
    lastPush = push;
}

+ (void)setInitialPushPayload:(NSData*)payload {
    if(initialPushPayload == nil) {
        initialPushPayload = payload;
    }
}

+ (NSData*)getLastPush {
    NSData* returnValue = lastPush;
    lastPush = nil;
    return returnValue;
}

+ (NSData*)getInitialPushPayload {
    return initialPushPayload;
}

+ (NSString*)getFCMToken {
    return fcmToken;
}

+ (NSString*)getAPNSToken {
    return apnsToken;
}

+ (void)deleteInstanceId:(void (^)(NSError *error))handler {
    // ATW removed deprecated call, not worked out relevance of trying to delete an instance
    //[[FIRInstanceID instanceID] deleteIDWithHandler:handler];
}

+ (void)hasPushPermission:(void (^)(NSNumber* yesNoOrNil))block {
    if ([UNUserNotificationCenter class] == nil) {
        [FCMPluginIOS9Support hasPushPermission:block];
        return;
    }
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    
    // *** TODO: Remove this test to set badge count, code commented out to remind us how to set the badge count in the future
    // need to implement 
    // dispatch_async(dispatch_get_main_queue(), ^{
    //    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
    //});
    
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings){
        switch (settings.authorizationStatus) {
            case UNAuthorizationStatusAuthorized: {
                block([NSNumber numberWithBool:YES]);
            }
            case UNAuthorizationStatusDenied: {
                block([NSNumber numberWithBool:NO]);
            }
            default: {
                block(nil);
            }
        }
    }];
}

- (NSString *)hexadecimalStringFromData:(NSData *)data {
    NSUInteger dataLength = data.length;
    if (dataLength == 0) {
        return nil;
    }

    const unsigned char *dataBuffer = data.bytes;
    NSMutableString *hexString  = [NSMutableString stringWithCapacity:(dataLength * 2)];
    for (int i = 0; i < dataLength; ++i) {
        [hexString appendFormat:@"%02x", dataBuffer[i]];
    }
    return [hexString copy];
}

@end
