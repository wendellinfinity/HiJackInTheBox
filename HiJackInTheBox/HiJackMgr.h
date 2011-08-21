//
//  HiJack.h
//  HiJack Library for easy interaction with a HiJack device. This library has two 
//  main functions, the 'send' function of HiJackMgr and the HiJackDelegate's 
//  receive function. 'send' is used to send a byte to the HiJack, while 'receive' is
//  triggered when the library decodes a message coming from the HiJack device.
//
//  Created by Thomas Schmid on 8/4/11.

#import <Foundation/Foundation.h>
#import "AudioUnit/AudioUnit.h"
#import "aurio_helper.h"
#import "CAStreamBasicDescription.h"

@protocol HiJackDelegate;


@interface HiJackMgr : NSObject 
{
	id <HiJackDelegate>			theDelegate;
	
	AudioUnit					rioUnit;
	AURenderCallbackStruct		inputProc;
	DCRejectionFilter*			dcFilter;
	CAStreamBasicDescription	thruFormat;
	Float64						hwSampleRate;

	UInt8						uartByteTransmit;
	BOOL						mute;
	BOOL						newByte;
	UInt32						maxFPS;

}
	
- (void) setDelegate:(id <HiJackDelegate>) delegate;
- (id) init;
- (int) send:(UInt8)data;
	
@property (nonatomic, assign)	AudioUnit				rioUnit;
@property (nonatomic, assign)	AURenderCallbackStruct	inputProc;
@property (nonatomic, assign)	int						unitIsRunning;
@property (nonatomic, assign)   UInt8					uartByteTransmit;
@property (nonatomic, assign)   UInt32					maxFPS;
@property (nonatomic, assign)	BOOL					newByte;
@end
	
	
@protocol HiJackDelegate <NSObject>
	
- (int) receive:(UInt8)data;
	
@end
