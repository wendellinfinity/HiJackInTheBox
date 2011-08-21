//
//  HiJackMgr.m
//  HiJack
//
//  Created by Thomas Schmid on 8/4/11.
//


#import "HiJackMgr.h"
#import "AudioUnit/AudioUnit.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import "CAXException.h"
#import "aurio_helper.h"

enum uart_state {
	STARTBIT = 0,
	SAMEBIT  = 1,
	NEXTBIT  = 2,
	STOPBIT  = 3,
	STARTBIT_FALL = 4,
	DECODE   = 5,
};

#define fc 1200
#define df 100
#define T (1/df)
#define N (SInt32)(T * THIS->hwSampleRate)
#define THRESHOLD 0 // threshold used to detect start bit
#define HIGHFREQ 1378.125 // baud rate. best to take a divisible number for 44.1kS/s
#define SAMPLESPERBIT 32 // (44100 / HIGHFREQ)  // how many samples per UART bit
//#define SAMPLESPERBIT 5 // (44100 / HIGHFREQ)  // how many samples per UART bit
//#define HIGHFREQ (44100 / SAMPLESPERBIT) // baud rate. best to take a divisible number for 44.1kS/s
#define LOWFREQ (HIGHFREQ / 2)
#define SHORT (SAMPLESPERBIT/2 + SAMPLESPERBIT/4) // 
#define LONG (SAMPLESPERBIT + SAMPLESPERBIT/2)    //
#define NUMSTOPBITS 100 // number of stop bits to send before sending next value.
//#define NUMSTOPBITS 10 // number of stop bits to send before sending next value.
#define AMPLITUDE (1<<24)

//#define DEBUG // verbose output about the bits and symbols
//#define DEBUG2 // output the byte values encoded
//#define DEBUGWAVE // enables output of the waveform after the 10th byte is sent. CAREFUL!!! Usually overloads debug output
//#define DECDEBUGBYTE // output the received byte only
//#define DECDEBUG // output for decoding debugging
//#define DECDEBUG2 // verbose decoding output


@implementation HiJackMgr

@synthesize rioUnit;
@synthesize inputProc;
@synthesize unitIsRunning;
@synthesize uartByteTransmit;
@synthesize maxFPS;
@synthesize newByte;

#pragma mark -Audio Session Interruption Listener

void rioInterruptionListener(void *inClientData, UInt32 inInterruption)
{
	printf("Session interrupted! --- %s ---", inInterruption == kAudioSessionBeginInterruption ? "Begin Interruption" : "End Interruption");
	
	HiJackMgr *THIS = (HiJackMgr*)inClientData;
	
	if (inInterruption == kAudioSessionEndInterruption) {
		// make sure we are again the active session
		AudioSessionSetActive(true);
		AudioOutputUnitStart(THIS->rioUnit);
	}
	
	if (inInterruption == kAudioSessionBeginInterruption) {
		AudioOutputUnitStop(THIS->rioUnit);
    }
}

#pragma mark -Audio Session Property Listener

void propListener(	void *                  inClientData,
				  AudioSessionPropertyID	inID,
				  UInt32                  inDataSize,
				  const void *            inData)
{
	HiJackMgr*THIS = (HiJackMgr*)inClientData;
	
	if (inID == kAudioSessionProperty_AudioRouteChange)
	{
		try {
			// if there was a route change, we need to dispose the current rio unit and create a new one
			XThrowIfError(AudioComponentInstanceDispose(THIS->rioUnit), "couldn't dispose remote i/o unit");		
			
			SetupRemoteIO(THIS->rioUnit, THIS->inputProc, THIS->thruFormat);
			
			UInt32 size = sizeof(THIS->hwSampleRate);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &THIS->hwSampleRate), "couldn't get new sample rate");
			
			XThrowIfError(AudioOutputUnitStart(THIS->rioUnit), "couldn't start unit");
			
			// we need to rescale the sonogram view's color thresholds for different input
			CFStringRef newRoute;
			size = sizeof(CFStringRef);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &newRoute), "couldn't get new audio route");
			if (newRoute)
			{	
				CFShow(newRoute);
/*				if (CFStringCompare(newRoute, CFSTR("Headset"), NULL) == kCFCompareEqualTo) // headset plugged in
				{
					colorLevels[0] = .3;				
					colorLevels[5] = .5;
				}
				else if (CFStringCompare(newRoute, CFSTR("Receiver"), NULL) == kCFCompareEqualTo) // headset plugged in
				{
					colorLevels[0] = 0;
					colorLevels[5] = .333;
					colorLevels[10] = .667;
					colorLevels[15] = 1.0;
					
				}			
				else
				{
					colorLevels[0] = 0;
					colorLevels[5] = .333;
					colorLevels[10] = .667;
					colorLevels[15] = 1.0;
					
				}
	*/
			}
		} catch (CAXException e) {
			char buf[256];
			fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		}
		
	}
}


#pragma mark -RIO Render Callback

static OSStatus	PerformThru(
							void						*inRefCon, 
							AudioUnitRenderActionFlags 	*ioActionFlags, 
							const AudioTimeStamp 		*inTimeStamp, 
							UInt32 						inBusNumber, 
							UInt32 						inNumberFrames, 
							AudioBufferList 			*ioData)
{
	HiJackMgr *THIS = (HiJackMgr *)inRefCon;
	OSStatus err = AudioUnitRender(THIS->rioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
	
	// TX vars
	static UInt32 phase = 0;
	static UInt32 phase2 = 0;
	static UInt32 lastPhase2 = 0;
	static SInt32 sample = 0;
	static SInt32 lastSample = 0;
	static int decState = STARTBIT;
	static int byteCounter = 1;
	static UInt8 parityTx = 0;
	
	// UART decoding
	static int bitNum = 0;
	static uint8_t uartByte = 0;
	
	// UART encode
	static uint32_t phaseEnc = 0;
	static uint32_t nextPhaseEnc = SAMPLESPERBIT;
	static uint8_t uartByteTx = 0x0;
	static uint32_t uartBitTx = 0;
	static uint8_t state = STARTBIT;
	static float uartBitEnc[SAMPLESPERBIT];
	static uint8_t currentBit = 1;
	static UInt8 parityRx = 0;
	
	if (err) { printf("PerformThru: error %d\n", (int)err); return err; }
	
	// Remove DC component
	//for(UInt32 i = 0; i < ioData->mNumberBuffers; ++i)
	//	THIS->dcFilter[i].InplaceFilter((SInt32*)(ioData->mBuffers[i].mData), inNumberFrames, 1);
	SInt32* lchannel = (SInt32*)(ioData->mBuffers[0].mData);
	//printf("sample %f\n", THIS->hwSampleRate);
	
	/************************************
	 * UART Decoding
	 ************************************/
#if 1
	for(int j = 0; j < inNumberFrames; j++) {
		float val = lchannel[j];
#ifdef DEBUGWAVE
		printf("%8ld, %8.0f\n", phase2, val);
#endif
#ifdef DECDEBUG2
		if(decState == DECODE)
			printf("%8ld, %8.0f\n", phase2, val);
#endif		
		phase2 += 1;
		if (val < THRESHOLD ) {
			sample = 0;
		} else {
			sample = 1;
		}
		if (sample != lastSample) {
			// transition
			SInt32 diff = phase2 - lastPhase2;
			switch (decState) {
				case STARTBIT:
					if (lastSample == 0 && sample == 1)
					{
						// low->high transition. Now wait for a long period
						decState = STARTBIT_FALL;
					}
					break;
				case STARTBIT_FALL:
					if (( SHORT < diff ) && (diff < LONG) )
					{
						// looks like we got a 1->0 transition.
						bitNum = 0;
						parityRx = 0;
						uartByte = 0;
						decState = DECODE;
					} else {
						decState = STARTBIT;
					}
					break;
				case DECODE:
					if (( SHORT < diff) && (diff < LONG) ) {
						// we got a valid sample.
						if (bitNum < 8) {
							uartByte = ((uartByte >> 1) + (sample << 7));
							bitNum += 1;
							parityRx += sample;
#ifdef DECDEBUG
							printf("Bit %d value %ld diff %ld parity %d\n", bitNum, sample, diff, parityRx & 0x01);
#endif
						} else if (bitNum == 8) {
							// parity bit
							if(sample != (parityRx & 0x01))
							{
#ifdef DECDEBUGBYTE
								printf(" -- parity %ld,  UartByte 0x%x\n", sample, uartByte);
#endif
								decState = STARTBIT;
							} else {
#ifdef DECDEBUG
								printf(" ++ good parity %ld, UartByte 0x%x\n", sample, uartByte);
#endif
								
								bitNum += 1;
							}
							
						} else {
							// we should now have the stopbit
							if (sample == 1) {
								// we have a new and valid byte!
#ifdef DECDEBUGBYTE
								printf(" ++ StopBit: %ld UartByte 0x%x\n", sample, uartByte);
#endif
								NSAutoreleasePool	 *autoreleasepool = [[NSAutoreleasePool alloc] init];
								//////////////////////////////////////////////
								// This is where we receive the byte!!!
								if([THIS->theDelegate respondsToSelector:@selector(receive:)]) {
                                    [THIS->theDelegate receive:uartByte];
								}
								//////////////////////////////////////////////
								[autoreleasepool release];
							} else {
								// not a valid byte.
#ifdef DECDEBUGBYTE
								printf(" -- StopBit: %ld UartByte %d\n", sample, uartByte);
#endif					
							}
							decState = STARTBIT;
						}
					} else if (diff > LONG) {
#ifdef DECDEBUG
						printf("diff too long %ld\n", diff);
#endif
						decState = STARTBIT;
					} else {
						// don't update the phase as we have to look for the next transition
						lastSample = sample;
						continue;
					}
					
					break;
				default:
					break;
			}
			lastPhase2 = phase2;
		}
		lastSample = sample;
	}
#endif
	
	if (THIS->mute == NO) {
		// prepare sine wave
		
		SInt32 values[inNumberFrames];
		/*******************************
		 * Generate 22kHz Tone
		 *******************************/
		
		double waves;
		//printf("inBusNumber %d, inNumberFrames %d, ioData->NumberBuffers %d mNumberChannels %d\n", inBusNumber, inNumberFrames, ioData->mNumberBuffers, ioData->mBuffers[0].mNumberChannels);
		//printf("size %d\n", ioData->mBuffers[0].mDataByteSize);
		//printf("sample rate %f\n", THIS->hwSampleRate);
		for(int j = 0; j < inNumberFrames; j++) {
			
			
			waves = 0;
			
			//waves += sin(M_PI * 2.0f / THIS->hwSampleRate * 22050.0 * phase);
			waves += sin(M_PI * phase+0.5); // This should be 22.050kHz
			
			waves *= (AMPLITUDE); // <--------- make sure to divide by how many waves you're stacking
			
			values[j] = (SInt32)waves;
			//values[j] += values[j]<<16;
			//printf("%d: %ld\n", phase, values[j]);
			phase++;
			
		}
		// copy sine wave into left channels.
		//memcpy(ioData->mBuffers[0].mData, values, ioData->mBuffers[0].mDataByteSize);
		// copy sine wave into right channels.
		memcpy(ioData->mBuffers[1].mData, values, ioData->mBuffers[1].mDataByteSize);
		/*******************************
		 * UART Encoding
		 *******************************/
		for(int j = 0; j< inNumberFrames; j++) {
			if ( phaseEnc >= nextPhaseEnc){
				if (uartBitTx >= NUMSTOPBITS && THIS->newByte == TRUE) {
					state = STARTBIT;
					THIS->newByte = FALSE;
				} else {
					state = NEXTBIT;
				}
			}
			
			switch (state) {
				case STARTBIT:
				{
					//////////////////////////////////////////////
					// FIXME: This is where we inject the message!
					//////////////////////////////////////////////

					//uartByteTx = (uint8_t)THIS->slider.value;
					uartByteTx = THIS->uartByteTransmit;
					//uartByteTx = 255;
					//uartByteTx += 1;
#ifdef DEBUG2
					printf("uartByteTx: 0x%x\n", uartByteTx);
#endif
					byteCounter += 1;
					uartBitTx = 0;
					parityTx = 0;
					
					state = NEXTBIT;
					// break; UNCOMMENTED ON PURPOSE. WE WANT TO FALL THROUGH!
				}
				case NEXTBIT:
				{
					uint8_t nextBit;
					if (uartBitTx == 0) {
						// start bit
						nextBit = 0;
					} else {
						if (uartBitTx == 9) {
							// parity bit
							nextBit = parityTx & 0x01;
						} else if (uartBitTx >= 10) {
							// stop bit
							nextBit = 1;
						} else {
							nextBit = (uartByteTx >> (uartBitTx - 1)) & 0x01;
							parityTx += nextBit;
						}
					}
					if (nextBit == currentBit) {
						if (nextBit == 0) {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = -sin(M_PI * 2.0f / THIS->hwSampleRate * HIGHFREQ * (p+1));
							}
						} else {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = sin(M_PI * 2.0f / THIS->hwSampleRate * HIGHFREQ * (p+1));
							}
						}
					} else {
						if (nextBit == 0) {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = sin(M_PI * 2.0f / THIS->hwSampleRate * LOWFREQ * (p+1));
							}
						} else {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = -sin(M_PI * 2.0f / THIS->hwSampleRate * LOWFREQ * (p+1));
							}
						}
					}
					
#ifdef DEBUG
					printf("BitTX %d: last %d next %d\n", uartBitTx, currentBit, nextBit);
#endif
					currentBit = nextBit;
					uartBitTx++;
					state = SAMEBIT;
					phaseEnc = 0;
					nextPhaseEnc = SAMPLESPERBIT;
					
					break;
				}
				default:
					break;
			}
			
			values[j] = (SInt32)(uartBitEnc[phaseEnc%SAMPLESPERBIT] * AMPLITUDE);
#ifdef DEBUG
			printf("val %ld\n", values[j]);
#endif
			phaseEnc++;
			
		}
		// copy data into right channel
		//memcpy(ioData->mBuffers[1].mData, values, ioData->mBuffers[1].mDataByteSize);
		// copy data into left channel
		memcpy(ioData->mBuffers[0].mData, values, ioData->mBuffers[0].mDataByteSize);
	}
	
	return err;
}


- (void) setDelegate:(id <HiJackDelegate>) delegate {
	theDelegate = delegate;
}

- (id) init {
	// Initialize our remote i/o unit
	
	inputProc.inputProc = PerformThru;
	inputProc.inputProcRefCon = self;
	
	newByte = FALSE;
	
	try {	
		
		// Initialize and configure the audio session
		XThrowIfError(AudioSessionInitialize(NULL, NULL, rioInterruptionListener, self), "couldn't initialize audio session");
		XThrowIfError(AudioSessionSetActive(true), "couldn't set audio session active\n");
		
		UInt32 audioCategory = kAudioSessionCategory_PlayAndRecord;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory), "couldn't set audio category");
		XThrowIfError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, propListener, self), "couldn't set property listener");
		
		Float32 preferredBufferSize = .005;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize), "couldn't set i/o buffer duration");
		
		UInt32 size = sizeof(hwSampleRate);
		XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &hwSampleRate), "couldn't get hw sample rate");
		
		XThrowIfError(SetupRemoteIO(rioUnit, inputProc, thruFormat), "couldn't setup remote i/o unit");
		
		dcFilter = new DCRejectionFilter[thruFormat.NumberChannels()];
		
		UInt32 maxFPSt;
		size = sizeof(maxFPSt);
		XThrowIfError(AudioUnitGetProperty(rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPSt, &size), "couldn't get the remote I/O unit's max frames per slice");
		self.maxFPS = maxFPSt;
		
		XThrowIfError(AudioOutputUnitStart(rioUnit), "couldn't start remote i/o unit");
		
		size = sizeof(thruFormat);
		XThrowIfError(AudioUnitGetProperty(rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &thruFormat, &size), "couldn't get the remote I/O unit's output client format");
		
		unitIsRunning = 1;
	}
	catch (CAXException &e) {
		char buf[256];
		fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
	}
	catch (...) {
		fprintf(stderr, "An unknown error occurred\n");
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
	}
	return self;
}

- (int) send:(UInt8) data {
	if (newByte == FALSE) {
		// transmitter ready
		self.uartByteTransmit = data;
		newByte = TRUE;
		return 0;
	} else {
		return 1;
	}
}


- (void)dealloc
{
	delete[] dcFilter;
	[super dealloc];

}

@end
