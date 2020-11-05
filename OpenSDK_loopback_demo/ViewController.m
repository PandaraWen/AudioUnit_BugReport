//
//  ViewController.m
//  OpenSDK_loopback_demo
//
//  Created by gowen on 2020/9/24.
//

#import "ViewController.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <sys/time.h>

#define kTraeAudioUnitOutputBus   0
#define kTraeAudioUnitInputBus    1
#define CHANNEL 2
#define BITS_PER_CHANNEL 16

char lastRecordRenderBuffer[48000 * 2 * 2]; // 1s 的 48K 双声道 PCM 数据容量
int lastRecordRenderByteSize;
BOOL isEnableLoopback;

static uint64_t xp_gettickcount()
{
    struct timeval current;
    gettimeofday(&current, NULL);
    uint64_t sec = current.tv_sec;
    return (sec * 1000 + current.tv_usec / 1000);
}

#pragma mark - Record and play handler
static OSStatus recordingHandler(void *                       inRefCon,
                                 AudioUnitRenderActionFlags * ioActionFlags,
                                 const AudioTimeStamp *       inTimeStamp,
                                 UInt32                       inBusNumber,
                                 UInt32                       inNumberFrames,
                                 AudioBufferList *            ioData)
{
    UInt32 dataTmpSize = inNumberFrames * CHANNEL * (BITS_PER_CHANNEL >> 3);
    lastRecordRenderByteSize = dataTmpSize;
    char *dataTmp = lastRecordRenderBuffer;
    
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mData = dataTmp;
    bufferList.mBuffers[0].mDataByteSize = dataTmpSize;
    bufferList.mBuffers[0].mNumberChannels = CHANNEL;
    
    AudioUnit *au = (AudioUnit *)inRefCon;
    OSStatus ret = AudioUnitRender(*au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList);
    if (ret != noErr) {
        NSLog(@"Render failed: %d", ret);
    }
    
    return ret;
}

static OSStatus playoutHandler(void *                        inRefCon,
                               AudioUnitRenderActionFlags *  ioActionFlags,
                               const AudioTimeStamp *        inTimeStamp,
                               UInt32                        inBusNumber,
                               UInt32                        inNumberFrames,
                               AudioBufferList *             ioData)
{
    char *dataBuffer = (char *)(ioData->mBuffers[0].mData);
    int dataSize = (int)(ioData->mBuffers[0].mDataByteSize);
    memset(dataBuffer, 0, dataSize);
    
    // 粗暴耳返
    if (isEnableLoopback) {
        memcpy(dataBuffer, lastRecordRenderBuffer, dataSize);
    }
    
    return noErr;
}

#pragma mark - ViewController

@interface ViewController ()

@property (nonatomic, assign) AudioUnit au;
@property (nonatomic, assign) BOOL isHeadphonePluggedIn;
@property (weak, nonatomic) IBOutlet UISwitch *shouldSetBuildInMicSwitch;
@property (weak, nonatomic) IBOutlet UITextView *logTextView;

@end

/**
 问题复现路径：
 1. 不插耳机，不开耳返，以 VPIO 模式启动
 2. 插耳机，以 RemoteIO 模式启动
 3. 打开耳返开关听声音
 */

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self updateHeadphonePlugginState];
    [self addNotificationObserver];
}

- (IBAction)onVPIOBtnClicked:(id)sender
{
    [self startAudioUnitWithSubType:kAudioUnitSubType_VoiceProcessingIO];
}

- (IBAction)onRemoteIOBtnClicked:(id)sender
{
    [self startAudioUnitWithSubType:kAudioUnitSubType_RemoteIO];
}

- (IBAction)onLoopbackSwitchChanged:(id)sender
{
    isEnableLoopback = ((UISwitch *)sender).isOn;
}

- (IBAction)onChangeInputPortBtnClicked:(id)sender
{
    [self changeInputPortToBuildInMic];
}

- (IBAction)onLogInfoBtnClicked:(id)sender {
    [self logCurrentRouteInfo];
}

- (void)setIsHeadphonePluggedIn:(BOOL)isHeadphonePluggedIn
{
    _isHeadphonePluggedIn = isHeadphonePluggedIn;
    NSLog(@"Is headphone plugged in: %d", isHeadphonePluggedIn);
}

- (void)log:(NSString *)msg
{
    NSString *str = [msg stringByAppendingFormat:@"\n%@", self.logTextView.text];
    self.logTextView.text = str;
}

#pragma mark - Audio Operation
- (void)updateHeadphonePlugginState
{
    AVAudioSessionRouteDescription* route = [[AVAudioSession sharedInstance] currentRoute];
    
    for (AVAudioSessionPortDescription* desc in [route outputs]) {
        if ([[desc portType] isEqualToString:AVAudioSessionPortHeadphones])
        {
            self.isHeadphonePluggedIn = YES;
            return;
        }
    }
    
    self.isHeadphonePluggedIn = NO;
}

- (void)stopAudioUnit
{
    if (self.au == NULL) {
        NSLog(@"Audio unit is NULL, will not stop");
        return;
    }
    
    OSStatus ret = 0;
    ret = AudioOutputUnitStop(self.au);
    NSLog(@"Stop audio unit: %d", ret);
    
    ret = AudioUnitUninitialize(self.au);
    NSLog(@"Uninit audio unit: %d", ret);
    
    ret = AudioComponentInstanceDispose(self.au);
    NSLog(@"Dispose audio unit: %d", ret);
    
    self.au = NULL;
}

/// 停止旧的 AudioUnit，创建新的 AudioUnit 并启动
- (void)startAudioUnitWithSubType:(UInt32)subType
{
    uint64_t tick_total = xp_gettickcount();
    
    if (subType != kAudioUnitSubType_RemoteIO &&
        subType != kAudioUnitSubType_VoiceProcessingIO) {
        NSLog(@"Subtype error");
        return;
    }
    
    uint64_t tick = xp_gettickcount();
    [self stopAudioUnit];
    uint64_t tock = xp_gettickcount();
    uint64_t dur = tock - tick;
    NSLog(@"[TimeCost] Stop audio unit: %lld", dur);
    [self log:[NSString stringWithFormat:@"[TimeCost] Stop audio unit: %lld", dur]];
    
    tick = xp_gettickcount();
    [self configAudioSession];
    tock = xp_gettickcount();
    dur = tock - tick;
    NSLog(@"[TimeCost] Config audio session: %lld", dur);
    [self log:[NSString stringWithFormat:@"[TimeCost] Config audio session: %lld", dur]];
    
    if (subType == kAudioUnitSubType_RemoteIO) {
        NSLog(@"Will create audio unit: RemoteIO");
    }
    else {
        NSLog(@"Will create audio unit: VPIO");
    }
     
    tick = xp_gettickcount();
    [self createAndStartAudioUnitWithSubType:subType];
    tock = xp_gettickcount();
    dur = tock - tick;
    NSLog(@"[TimeCost] Create and start audio unit: %lld", dur);
    [self log:[NSString stringWithFormat:@"[TimeCost] Create and start audio unit: %lld", dur]];
    
    uint64_t tock_total = xp_gettickcount();
    uint64_t dur_total = tock_total - tick_total;
    NSLog(@"[TimeCost] Start audio unit total: %lld", dur_total);
    [self log:[NSString stringWithFormat:@"[TimeCost] Start audio unit total: %lld", dur_total]];
}

- (void)createAndStartAudioUnitWithSubType:(UInt32)subType
{
    if (self.au != NULL) {
        NSLog(@"There is an audio unit running, will not create");
        return;
    }
    
    AudioComponentDescription audioCompDesc;
    audioCompDesc.componentType         = kAudioUnitType_Output;
    audioCompDesc.componentSubType      = subType;
    audioCompDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    audioCompDesc.componentFlags        = 0;
    audioCompDesc.componentFlagsMask    = 0;
    
    AudioComponent comp = AudioComponentFindNext(NULL, &audioCompDesc);
    if (comp == NULL) {
        NSLog(@"Audio component find next failed");
        return;
    }
    
    // Create audio unit
    OSStatus ret = AudioComponentInstanceNew(comp, &_au);
    if (ret != noErr) {
        NSLog(@"Create audio unit failed: %d", ret);
        return;
    }
    
    // Enable output
    UInt32 enableIO = 1;
    ret = AudioUnitSetProperty(self.au,
                               kAudioOutputUnitProperty_EnableIO,
                               kAudioUnitScope_Output,
                               kTraeAudioUnitOutputBus,
                               &enableIO,
                               sizeof(enableIO));
    if (ret != noErr) {
        NSLog(@"Could not enable output: %d", ret);
        return;
    }
    
    // Enable input
    ret = AudioUnitSetProperty(self.au,
                               kAudioOutputUnitProperty_EnableIO,
                               kAudioUnitScope_Input,
                               kTraeAudioUnitInputBus,
                               &enableIO,
                               sizeof(enableIO));
    if (ret != noErr) {
        NSLog(@"Could not enable input: %d", ret);
        return;
    }
    
    // Set IOBuffer
    NSError *error;
    double ioBufferDurInSec = isEnableLoopback ? 0.01 : 0.02;
    [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:ioBufferDurInSec error:&error];
    if (error) {
        NSLog(@"Set IOBuffer dur failed: %@", error);
        return;
    }
    else {
        NSLog(@"Set IOBuffer dur success: %.02f", [[AVAudioSession sharedInstance] IOBufferDuration]);
    }
    
    // Capture callback
    AURenderCallbackStruct recordCallbackStruct;
    memset(&recordCallbackStruct, 0, sizeof(recordCallbackStruct));
    recordCallbackStruct.inputProc = recordingHandler;
    recordCallbackStruct.inputProcRefCon = &_au;
    
    ret = AudioUnitSetProperty(self.au,
                               kAudioOutputUnitProperty_SetInputCallback,
                               kAudioUnitScope_Global,
                               kTraeAudioUnitInputBus,
                               &recordCallbackStruct,
                               sizeof(recordCallbackStruct));
    if (ret != noErr) {
        NSLog(@"Set intput callback failed: %d", ret);
        return;
    }
    
    // Set input stream format
    AudioStreamBasicDescription inputFormat;
    memset(&inputFormat, 0, sizeof(inputFormat));
    inputFormat.mSampleRate        = self.isHeadphonePluggedIn ? 48000 : 32000;
    inputFormat.mChannelsPerFrame  = 2;
    inputFormat.mBitsPerChannel    = 16;
    inputFormat.mBytesPerFrame     = (inputFormat.mBitsPerChannel >> 3) * inputFormat.mChannelsPerFrame;
    inputFormat.mFramesPerPacket   = 1;
    inputFormat.mBytesPerPacket    = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket;
    inputFormat.mFormatID          = kAudioFormatLinearPCM;
    inputFormat.mFormatFlags       = kAudioFormatFlagsNativeEndian | kLinearPCMFormatFlagIsPacked | kLinearPCMFormatFlagIsSignedInteger;
    
    ret = AudioUnitSetProperty(self.au,
                               kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Output,
                               kTraeAudioUnitInputBus,
                               &inputFormat,
                               sizeof(inputFormat));
    if (ret != noErr) {
        NSLog(@"Set intput stream format failed: %d", ret);
        return;
    }
    
    // Playout callback
    AURenderCallbackStruct playoutCallbackStruct;
    memset(&playoutCallbackStruct, 0, sizeof(playoutCallbackStruct));
    playoutCallbackStruct.inputProc = playoutHandler;
    playoutCallbackStruct.inputProcRefCon = &_au;
    
    ret = AudioUnitSetProperty(self.au,
                               kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input,
                               kTraeAudioUnitOutputBus,
                               &playoutCallbackStruct,
                               sizeof(playoutCallbackStruct));
    if (ret != noErr) {
        NSLog(@"Set output callback failed: %d", ret);
        return;
    }
    
    // Output stream format
    AudioStreamBasicDescription outputFormat;
    memset(&outputFormat, 0, sizeof(outputFormat));
    outputFormat.mSampleRate        = self.isHeadphonePluggedIn ? 48000 : 32000;
    outputFormat.mChannelsPerFrame  = 2;
    outputFormat.mBitsPerChannel    = 16;
    outputFormat.mBytesPerFrame     = (outputFormat.mBitsPerChannel >> 3) * outputFormat.mChannelsPerFrame;
    outputFormat.mFramesPerPacket   = 1;
    outputFormat.mBytesPerPacket    = outputFormat.mBytesPerFrame * outputFormat.mFramesPerPacket;
    outputFormat.mFormatID          = kAudioFormatLinearPCM;
    outputFormat.mFormatFlags       = kAudioFormatFlagsNativeEndian | kLinearPCMFormatFlagIsPacked | kLinearPCMFormatFlagIsSignedInteger;
    
    ret = AudioUnitSetProperty(self.au,
                               kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input,
                               kTraeAudioUnitOutputBus,
                               &outputFormat,
                               sizeof(outputFormat));
    if (ret != noErr) {
        NSLog(@"Set output stream format fail: %d", ret);
        return;
    }
    
    // Intialize
    ret = AudioUnitInitialize(self.au);
    if (ret != noErr) {
        NSLog(@"Initialize audio unit failed: %d", ret);
        return;
    }
    
    uint64_t tick = xp_gettickcount();
    // Override output audio port
    AVAudioSessionPortOverride overridePort = self.isHeadphonePluggedIn ? AVAudioSessionPortOverrideNone : AVAudioSessionPortOverrideSpeaker;
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:overridePort error:&error];
    if (error) {
        NSLog(@"Override audio port failed: %@", error);
        return;
    }
    uint64_t tock = xp_gettickcount();
    uint64_t dur = tock - tick;
    NSLog(@"[TimeCost] Override audio port: %lld", dur);
    [self log:[NSString stringWithFormat:@"[TimeCost] Override audio port: %lld", dur]];
    
    tick = xp_gettickcount();
    ret = AudioOutputUnitStart(self.au);
    if (ret != noErr) {
        NSLog(@"Start audio unit failed: %d", ret);
        return;
    }
    tock = xp_gettickcount();
    dur = tock - tick;
    NSLog(@"[TimeCost] Audio unit start: %lld", dur);
    [self log:[NSString stringWithFormat:@"[TimeCost] Audio unit start: %lld", dur]];
    
    NSLog(@"Start audio unit success: %d", ret);
}

- (void)changeInputPortToBuildInMic
{
    uint64_t tick = xp_gettickcount();
    
    if (@available(iOS 14.0 , *))
    {
        //Input
        AVAudioSession* myAudioSession = [AVAudioSession sharedInstance];
        NSArray* inputs = [myAudioSession availableInputs];
        
        for (AVAudioSessionPortDescription* port in inputs)
        {
            NSLog(@"[BuiltInMic] There are %u data sources for port :%s\n", (unsigned)[port.dataSources count], [port.portName UTF8String]);
        }
        
        // Locate the Port corresponding to the built-in microphone.
        AVAudioSessionPortDescription* builtInMicPort = nil;
        for (AVAudioSessionPortDescription* port in inputs)
        {
            if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic])
            {
                builtInMicPort = port;
                break;
            }
        }
        
        NSLog(@" [BuiltInMic] There are %u data sources for port :%s\n", (unsigned)[builtInMicPort.dataSources count], [builtInMicPort.portName UTF8String]);
        
        {//setPreferredInput to builtInMicPort
            NSError *error;
            [myAudioSession setPreferredInput:builtInMicPort error:&error];
            if (error)
            {
                // an error occurred. Handle it!
                NSLog(@"setPreferredInput failed: %@", error);
            }
            else
            {
                NSLog(@"setPreferredInput success");
            }
        }
        
        {//setPreferredInput to nil
            NSError *error;
            [myAudioSession setPreferredInput:nil error:&error];
            if (error)
            {
                // an error occurred. Handle it!
                NSLog(@"setPreferredInput failed: %@", error);
            }
            else
            {
                NSLog(@"setPreferredInput success");
                
            }
        }
        
        [self logCurrentRouteInfo];
    }
    
    uint64_t tock = xp_gettickcount();
    uint64_t dur = tock - tick;
    NSLog(@"[TimeCost] Change input port: %lld", dur);
    [self log:[NSString stringWithFormat:@"[TimeCost] Change input port: %lld", dur]];
}

- (void)logCurrentRouteInfo
{
    AVAudioSessionRouteDescription *currentRoute = [[AVAudioSession sharedInstance] currentRoute];
    NSString *outputType = currentRoute.outputs.firstObject.portType;
    NSString *outputName = currentRoute.outputs.firstObject.portName;
        
    NSString *inputType = currentRoute.inputs.firstObject.portType;
    NSString *inputName = currentRoute.inputs.firstObject.portName;
    
    NSLog(@"Current route intput: %@, %@; output: %@, %@", inputType, inputName, outputType, outputName);
}

- (void)configAudioSession
{
    AVAudioSession * audioSession = [AVAudioSession sharedInstance];
    AVAudioSessionCategoryOptions categoryOptions = [audioSession categoryOptions];
    
    categoryOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
    
    NSError *err;
    NSString *modeStr;
    double samperate;
    if (self.isHeadphonePluggedIn) {
        modeStr = AVAudioSessionModeDefault;
        samperate = 48000;
    }
    else {
        modeStr = AVAudioSessionModeVoiceChat;
        samperate = 32000;
    }
    
    // Set category
    BOOL ret = [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                                   mode:AVAudioSessionModeDefault
                                options:categoryOptions
                                  error:&err];
    NSLog(@"Set audio session category: %d, err: %@", ret, err);
    
    // Active audioSession
    ret = [audioSession setActive:YES
                      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                            error:&err];
    NSLog(@"Active audio session: %d, err: %@", ret, err);
    
    // Sample rate
    ret = [audioSession setPreferredSampleRate:samperate
                                         error:&err];
    double curSampleRate = [[AVAudioSession sharedInstance] sampleRate];
    NSLog(@"Set sample rate to: %.02f, ret: %d, err: %@, cur: %.02f", samperate, ret, err, curSampleRate);
    
    
    if (self.shouldSetBuildInMicSwitch.isOn) {
        [self changeInputPortToBuildInMic];
    }
}

#pragma mark - Notification
- (void)addNotificationObserver
{
    NSLog(@"Add notification observer");
    [[NSNotificationCenter defaultCenter] addObserver:self
    selector:@selector(onAudioSessionRouteChange:)
        name:AVAudioSessionRouteChangeNotification
      object:nil];
}

- (void)onAudioSessionRouteChange:(NSNotification *)notifi
{
    unsigned int routeChangeReason = [[[notifi userInfo] objectForKey:AVAudioSessionRouteChangeReasonKey] unsignedIntValue];
    
    AVAudioSessionRouteDescription *oldRoute = [notifi.userInfo objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    NSString *oldInputType = [oldRoute.inputs.firstObject portType];
    NSString *oldInputName = [oldRoute.inputs.firstObject portName];
    NSString *oldOutputType = [oldRoute.outputs.firstObject portType];
    NSString *oldOutputName = [oldRoute.outputs.firstObject portName];

    AVAudioSessionRouteDescription *newRoute = [[AVAudioSession sharedInstance] currentRoute];
    NSString *newInputType = [newRoute.inputs.firstObject portType];
    NSString *newInputName = [newRoute.inputs.firstObject portName];
    NSString *newOutputType = [newRoute.outputs.firstObject portType];
    NSString *newOutputName = [newRoute.outputs.firstObject portName];
    
    NSLog(@"Route changed, \n old input: %@, %s; \n old output: %@, %s; \n new intput: %@, %s; \n new output: %@, %s \n reason:%ld",
          oldInputType, oldInputName.UTF8String,
          oldOutputType, oldOutputName.UTF8String,
          newInputType, newInputName.UTF8String,
          newOutputType, newOutputName.UTF8String,
          (long)routeChangeReason);
    
    self.isHeadphonePluggedIn = [newOutputType isEqualToString:AVAudioSessionPortHeadphones];
    
//    switch (routeChangeReason)
//    {
//        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
//            if ([newOutput isEqualToString:AVAudioSessionPortHeadphones]) {
//                self.isHeadphonePluggedIn = YES;
//            }
//            break;
//        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
//        case AVAudioSessionRouteChangeReasonOverride:
//            self.isHeadphonePluggedIn = NO;
//            break;
//        default:
//            break;
//    }
}

/**
 typedef NS_ENUM(NSUInteger, AVAudioSessionRouteChangeReason) {
     /// The reason is unknown.
     AVAudioSessionRouteChangeReasonUnknown = 0,

     /// A new device became available (e.g. headphones have been plugged in).
     AVAudioSessionRouteChangeReasonNewDeviceAvailable = 1,

     /// The old device became unavailable (e.g. headphones have been unplugged).
     AVAudioSessionRouteChangeReasonOldDeviceUnavailable = 2,

     /// The audio category has changed (e.g. AVAudioSessionCategoryPlayback has been changed to
     /// AVAudioSessionCategoryPlayAndRecord).
     AVAudioSessionRouteChangeReasonCategoryChange = 3,

     /// The route has been overridden (e.g. category is AVAudioSessionCategoryPlayAndRecord and
     /// the output has been changed from the receiver, which is the default, to the speaker).
     AVAudioSessionRouteChangeReasonOverride = 4,

     /// The device woke from sleep.
     AVAudioSessionRouteChangeReasonWakeFromSleep = 6,

     /// Returned when there is no route for the current category (for instance, the category is
     /// AVAudioSessionCategoryRecord but no input device is available).
     AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory = 7,

     /// Indicates that the set of input and/our output ports has not changed, but some aspect of
     /// their configuration has changed.  For example, a port's selected data source has changed.
     /// (Introduced in iOS 7.0, watchOS 2.0, tvOS 9.0).
     AVAudioSessionRouteChangeReasonRouteConfigurationChange = 8
 };
 */

@end
