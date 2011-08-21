//
//  HiJackInTheBoxAppDelegate.h
//  HiJackInTheBox
//
//  Created by Wendell on 21/08/2011.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "HiJackMgr.h"

@class HiJackInTheBoxViewController;

@interface HiJackInTheBoxAppDelegate : NSObject <UIApplicationDelegate,HiJackDelegate> {
    HiJackMgr* hiJackMgr;
}

@property (nonatomic, retain) IBOutlet UIWindow *window;

@property (nonatomic, retain) IBOutlet HiJackInTheBoxViewController *viewController;

@end
