#include "game.h"

#include <Cocoa/Cocoa.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <IOKit/hid/IOHidLib.h>

#define SND_SIZE 8192

static AudioQueueRef audioQueue;

void soundFill(void* inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    void* frames = inBuffer->mAudioData;
    UInt32 count = inBuffer->mAudioDataBytesCapacity / 4;
    Sound::fill((Sound::Frame*)frames, count);
    inBuffer->mAudioDataByteSize = count * 4;
    AudioQueueEnqueueBuffer(audioQueue, inBuffer, 0, NULL);
	// TODO: mutex
}

void soundInit() {
    AudioStreamBasicDescription deviceFormat;
    deviceFormat.mSampleRate        = 44100;
    deviceFormat.mFormatID          = kAudioFormatLinearPCM;
    deviceFormat.mFormatFlags       = kLinearPCMFormatFlagIsSignedInteger;
    deviceFormat.mBytesPerPacket    = 4;
    deviceFormat.mFramesPerPacket   = 1;
    deviceFormat.mBytesPerFrame     = 4;
    deviceFormat.mChannelsPerFrame  = 2;
    deviceFormat.mBitsPerChannel    = 16;
    deviceFormat.mReserved          = 0;

    AudioQueueNewOutput(&deviceFormat, soundFill, NULL, NULL, NULL, 0, &audioQueue);

    for (int i = 0; i < 2; i++) {
        AudioQueueBufferRef mBuffer;
        AudioQueueAllocateBuffer(audioQueue, SND_SIZE, &mBuffer);
        soundFill(NULL, audioQueue, mBuffer);
    }
    AudioQueueStart(audioQueue, NULL);
}

// common input functions
InputKey keyToInputKey(int code) {
    static const int codes[] = {
        0x7B, 0x7C, 0x7E, 0x7D, 0x31, 0x24, 0x35, 0x38, 0x3B, 0x3A,
        0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19,                   // 0..9
        0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // A..M
        0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // N..Z
    };

    for (int i = 0; i < sizeof(codes) / sizeof(codes[0]); i++)
        if (codes[i] == code)
            return (InputKey)(ikLeft + i);
    return ikNone;
}

InputKey mouseToInputKey(int btn) {
    switch (btn) {
        case 1 : return ikMouseL;
        case 2 : return ikMouseR;
        case 3 : return ikMouseM;
    }
    return ikNone;
}

/*
 * Returns the value as a double from 0 (min) to 1 (max) based on element min
 * and max values. You'd think IOHIDValueGetScaledValue would do that. You'd
 * be wrong.
 */
double logicalScaledValue(IOHIDValueRef value) {
    IOHIDElementRef element = IOHIDValueGetElement(value);
    CFIndex min = IOHIDElementGetLogicalMin(element);
    CFIndex max = IOHIDElementGetLogicalMax(element);
    return (double) (IOHIDValueGetIntegerValue(value) - min) / (max - min);
}

/*
 * Returns the value as a double from -1 (min) to 1 (max) based on element min
 * and max values. Also adds a dead zone of 10%.
 */
double adjustedAxisValue(IOHIDValueRef value) {
    const double deadzone = 0.1;
    
    double centeredValue = logicalScaledValue(value) * 2.0 - 1.0;
    double offsetFromCenter = fabs(centeredValue);
    double adjustedOffset = fmax((offsetFromCenter - deadzone) / (1.0 - deadzone), 0.0);
    return copysign(adjustedOffset, centeredValue);
}

void setHatswitchValue(CFIndex value) {
    Input::setPos(ikJoyPOV, value);
}

/*
 * Gets the value from a DPad element. This implements a dead zone of 25%
 * (chosen because it works well for me). If the Dpad only has on/off then that
 * is reported directly.
 */
CFIndex adjustedDPadValue(IOHIDValueRef value) {
    CFIndex intValue = IOHIDValueGetIntegerValue(value);
    
    IOHIDElementRef element = IOHIDValueGetElement(value);
    CFIndex min = IOHIDElementGetLogicalMin(element);
    CFIndex max = IOHIDElementGetLogicalMax(element);
    if ((intValue - min) < (max - min)/4)
        return 0;
    return intValue;
}

// Store existing DPad values, because we only ever get the new one
// (Could probably do some trickery to find the values for the others at the
// same time, but this is easier). DPad can be pressure sensitive so use full
// range values.
CFIndex lastDPadUpValue;
CFIndex lastDPadLeftValue;
CFIndex lastDPadRightValue;
CFIndex lastDPadDownValue;

// Map the DPad values to something useful
// Right now, that means mapping them to hatswitch values. This is very far from
// optimal, because it ignores the pressure values. Ideally they should be
// mapped to Left Stick (or just a category for themselves). But this way, the
// game is immediately playable.
void mapDPadValues() {
    if (lastDPadUpValue > lastDPadDownValue) {
        // Up
        if (lastDPadRightValue > lastDPadLeftValue) {
            // Up-Right
            setHatswitchValue(2);
        } else if (lastDPadLeftValue > lastDPadRightValue) {
            // Up-Left
            setHatswitchValue(8);
        } else {
            // Only up
            setHatswitchValue(1);
        }
    } else if (lastDPadDownValue > lastDPadUpValue) {
        // Down
        if (lastDPadRightValue > lastDPadLeftValue) {
            // Down-Right
            setHatswitchValue(4);
        } else if (lastDPadLeftValue > lastDPadRightValue) {
            // Down-Left
            setHatswitchValue(6);
        } else {
            // Only down
            setHatswitchValue(5);
        }
    } else if (lastDPadRightValue > lastDPadLeftValue) {
        // Only right
        setHatswitchValue(3);
    } else if (lastDPadLeftValue > lastDPadRightValue) {
        // Only left
        setHatswitchValue(7);
    } else {
        // Both axis balanced, nothing at all
        setHatswitchValue(0);
    }
}

/*
 * Processes a value from hidValueCallback that belongs to the GenericDesktop
 * usage page, representing mostly joystick axis, hatswitch, dpad
 */
void processHIDGenericDesktopInput(IOHIDValueRef value) {
    switch (IOHIDElementGetUsage(IOHIDValueGetElement(value))) {
        case kHIDUsage_GD_X:
            Input::setPos(ikJoyR, vec2(adjustedAxisValue(value), Input::joy.R.y));
            break;
        case kHIDUsage_GD_Y:
            Input::setPos(ikJoyR, vec2(Input::joy.R.x, adjustedAxisValue(value)));
            break;
        case kHIDUsage_GD_Z:
            Input::setPos(ikJoyL, vec2(adjustedAxisValue(value), Input::joy.L.y));
            break;
        case kHIDUsage_GD_Rz:
            Input::setPos(ikJoyL, vec2(Input::joy.L.x, adjustedAxisValue(value)));
            break;
        case kHIDUsage_GD_Hatswitch:
            setHatswitchValue(IOHIDValueGetIntegerValue(value));
            break;
        case kHIDUsage_GD_DPadUp:
            lastDPadUpValue = adjustedDPadValue(value);
            mapDPadValues();
            break;
        case kHIDUsage_GD_DPadLeft:
            lastDPadLeftValue = adjustedDPadValue(value);
            mapDPadValues();
            break;
        case kHIDUsage_GD_DPadRight:
            lastDPadRightValue = adjustedDPadValue(value);
            mapDPadValues();
            break;
        case kHIDUsage_GD_DPadDown:
            lastDPadDownValue = adjustedDPadValue(value);
            mapDPadValues();
            break;
        default:
            NSLog(@"Got int value %ld (scaled %f) for element usage 0x%x", IOHIDValueGetIntegerValue(value), IOHIDValueGetScaledValue(value, kIOHIDValueScaleTypeCalibrated), IOHIDElementGetUsage(IOHIDValueGetElement(value)));
            break;
    }
}

/*
 * Maps a joystick button to a key on the gamepad model used internally. Mapping
 * is guessed and probably not optimal.
 */
InputKey joyButtonToKey(uint32_t button) {
    switch(button) {
        case 0: return ikJoyA;
        case 1: return ikJoyB;
        case 2: return ikJoyX;
        case 3: return ikJoyY;
        case 4: return ikJoyLB;
        case 5: return ikJoyRB;
        case 6: return ikJoyLT;
        case 7: return ikJoyRT;
        case 9: return ikJoySelect;
        case 8: return ikJoyStart;
        default: return ikNone;
    }
}

/*
 * Process values for elements on the "button" page. This also includes the
 * triggers on gamepads. Currently, their pressure information is ignored, but
 * it doesn't have to be.
 */
void processHIDButtonInput(IOHIDValueRef value) {
    // Note: LT, RT also land here. We're deliberately throwing away their
    // pressure information
    uint32_t button = IOHIDElementGetUsage(IOHIDValueGetElement(value)) - kHIDUsage_Button_1;
    bool down = IOHIDValueGetIntegerValue(value) != 0;
    Input::setDown(joyButtonToKey(button), down);
}

/*
 * Process values for elements from the "Consumer" page. MFI gamepads register
 * the "pause" button here.
 */
void processConsumerInput(IOHIDValueRef value) {
    switch (IOHIDElementGetUsage(IOHIDValueGetElement(value))) {
        case kHIDUsage_Csmr_ACHome:
            // Pause button
            Input::setDown(ikJoyStart, IOHIDValueGetIntegerValue(value) != 0);
            break;
        default:
            NSLog(@"Got int value %ld (scaled %f) for consumer usage 0x%x", IOHIDValueGetIntegerValue(value), IOHIDValueGetScaledValue(value, kIOHIDValueScaleTypeCalibrated), (int) IOHIDElementGetUsage(IOHIDValueGetElement(value)));
    }
}

/*
 * Callback called by the HID manager when an input value changes.
 */
void hidValueCallback (void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    if (result != kIOReturnSuccess)
        return;
    
    IOHIDElementRef element = IOHIDValueGetElement(value);
    switch (IOHIDElementGetUsagePage(element)) {
        case kHIDPage_GenericDesktop:
            processHIDGenericDesktopInput(value);
            break;
        case kHIDPage_Button:
            processHIDButtonInput(value);
            break;
        case kHIDPage_Consumer:
            processConsumerInput(value);
            break;
        default:
            NSLog(@"Got int value %ld (scaled %f) for page 0x%x usage 0x%x", IOHIDValueGetIntegerValue(value), IOHIDValueGetScaledValue(value, kIOHIDValueScaleTypeCalibrated), IOHIDElementGetUsagePage(element), IOHIDElementGetUsage(element));
    }
}


void setupJoystickInput() {
    IOHIDManagerRef hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDManagerOptionNone);
    
    NSDictionary *matchingGamepad = @{
        @(kIOHIDDeviceUsagePageKey): @(kHIDPage_GenericDesktop),
        @(kIOHIDDeviceUsageKey): @(kHIDUsage_GD_GamePad)
    };
    NSDictionary *matchingJoystick = @{
        @(kIOHIDDeviceUsagePageKey): @(kHIDPage_GenericDesktop),
        @(kIOHIDDeviceUsageKey): @(kHIDUsage_GD_Joystick)
    };
    NSArray *matchDicts = @[ matchingGamepad, matchingJoystick ];
    
    IOHIDManagerSetDeviceMatchingMultiple(hidManager, (__bridge CFArrayRef) matchDicts);
    IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(hidManager, kIOHIDOptionsTypeNone);
    IOHIDManagerRegisterInputValueCallback(hidManager, hidValueCallback, nullptr);
}

int lastTime;
int fpsTime;
int fps;
CVDisplayLinkRef displayLink;

int getTime() {
    static mach_timebase_info_data_t timebaseInfo;
    if (timebaseInfo.denom == 0) {
        mach_timebase_info(&timebaseInfo);
    }
    
    uint64_t absolute = mach_absolute_time();
    uint64_t milliseconds = absolute * timebaseInfo.numer / (timebaseInfo.denom * 1000000ULL);
    return int(milliseconds);
}

/*
 * Specific OpenGLView. This subclass is necessary primarily to handle input.
 * Capturing and dispatching events manually on OS X is definitely not worth it.
 */
@interface OpenLaraGLView : NSOpenGLView

@end

@implementation OpenLaraGLView

- (InputKey)inputKeyForMouseEvent:(NSEvent *)theEvent {
    switch (theEvent.buttonNumber) {
        case 0: return ikMouseL;
        case 1: return ikMouseR;
        case 2: return ikMouseM;
        default: return ikNone;
    }
}

- (vec2)inputPositionForMouseEvent:(NSEvent *)theEvent {
    NSPoint inWindow = theEvent.locationInWindow;
    NSPoint inView = [self convertPoint:inWindow fromView:nil];
    // TODO Do we need to flip y, due to OS X having the origin at the bottom
    // left as opposed to top left in every single other system? The original
    // code didn't so I won't either for now.
    return vec2(inView.x, inView.y);
}

- (void)mouseDown:(NSEvent *)theEvent {
    InputKey inputKey = [self inputKeyForMouseEvent:theEvent];
    Input::setPos(inputKey, [self inputPositionForMouseEvent:theEvent]);
    Input::setDown(inputKey, true);
}

- (void)rightMouseDown:(NSEvent *)theEvent {
    [self mouseDown:theEvent];
}

- (void)otherMouseDown:(NSEvent *)theEvent {
    [self mouseDown:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent {
    InputKey inputKey = [self inputKeyForMouseEvent:theEvent];
    Input::setPos(inputKey, [self inputPositionForMouseEvent:theEvent]);
    Input::setDown(inputKey, false);
}

- (void)rightMouseUp:(NSEvent *)theEvent {
    [self mouseUp:theEvent];
}

- (void)otherMouseUp:(NSEvent *)theEvent {
    [self mouseUp:theEvent];
}

- (void)mouseDragged:(NSEvent *)theEvent {
    InputKey inputKey = [self inputKeyForMouseEvent:theEvent];
    Input::setPos(inputKey, [self inputPositionForMouseEvent:theEvent]);
}

- (void)rightMouseDragged:(NSEvent *)theEvent {
    [self mouseDragged:theEvent];
}

- (void)otherMouseDragged:(NSEvent *)theEvent {
    [self mouseDragged:theEvent];
}

- (void)keyDown:(NSEvent *)theEvent {
    unsigned short keyCode = theEvent.keyCode;
    Input::setDown(keyToInputKey(keyCode), true);
}

- (void)keyUp:(NSEvent *)theEvent {
    unsigned short keyCode = theEvent.keyCode;
    Input::setDown(keyToInputKey(keyCode), false);
}

- (void)flagsChanged:(NSEvent *)theEvent {
    NSEventModifierFlags modifiers = theEvent.modifierFlags;
    Input::setDown(ikShift, modifiers & NSShiftKeyMask);
    Input::setDown(ikCtrl,  modifiers & NSControlKeyMask);
    Input::setDown(ikAlt,   modifiers & NSAlternateKeyMask);
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)reshape {
    NSRect bounds = self.bounds;
    Core::width  = bounds.size.width;
    Core::height = bounds.size.height;
}

@end

/*
 * Delegate to deal with things that happen at the window level
 */
@interface OpenLaraDelegate : NSObject<NSWindowDelegate, NSApplicationDelegate>
- (void)loadLevel:(id)sender;
@end

@implementation OpenLaraDelegate

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    CVDisplayLinkStop(displayLink);
    Game::free();
    Game::init(filename.fileSystemRepresentation, false);
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:filename isDirectory:NO]];
    CVDisplayLinkStart(displayLink);
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    [[NSApplication sharedApplication] terminate:self];
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
    // Pause game
    CVDisplayLinkStop(displayLink);
    Input::reset();
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
    // End paused game.
    lastTime = getTime();
    CVDisplayLinkStart(displayLink);
}

- (void)loadLevel:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.allowsOtherFileTypes = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.resolvesAliases = YES;
    panel.allowedFileTypes = @[ @"phd" ];
    
    [panel beginSheetModalForWindow:[[NSApplication sharedApplication] mainWindow] completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton)
            return;
        
        CVDisplayLinkStop(displayLink);
        Game::free();
        Game::init(panel.URL.fileSystemRepresentation, false);
        [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:panel.URL];
        CVDisplayLinkStart(displayLink);
    }];
}

@end

char *contentPath;

/*
 * Callback for the CVDisplayLink, an OS X mechanism to get precise timing for
 * multi-media applications. This runs the whole game loop, for simplicitly's
 * sake. This is not really the idea of the displayLinkCallback, which should
 * more or less just swap the OpenGL buffer here and at least have the update
 * running in a different thread entirely. But it works.
 */
CVReturn displayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *now, const CVTimeStamp *outputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *context) {
    OpenLaraGLView *view = (OpenLaraGLView *) context;
    [view.openGLContext makeCurrentContext];
    
    // TODO: This should probably get the time from the outputTime parameter
    int time = getTime();
    if (time <= lastTime)
        return kCVReturnSuccess;
    
    // TODO: This should probably run the update in a separate thread
    // and only do rendering here
    float delta = (time - lastTime) * 0.001f;
    while (delta > EPS) {
        Core::deltaTime = min(delta, 1.0f / 30.0f);
        Game::update();
        delta -= Core::deltaTime;
    }
    lastTime = time;
    
    // TODO: Rendering should probably happen a bit in advance with only the
    // flushBuffer here
    Core::stats.dips = 0;
    Core::stats.tris = 0;
    Game::render();
    [view.openGLContext flushBuffer];
    
    if (fpsTime < getTime()) {
        LOG("FPS: %d DIP: %d TRI: %d\n", fps, Core::stats.dips, Core::stats.tris);
        fps = 0;
        fpsTime = getTime() + 1000;
    } else
        fps++;

    return kCVReturnSuccess;
}

int main() {
    NSApplication *application = [NSApplication sharedApplication];
    OpenLaraDelegate *delegate = [[OpenLaraDelegate alloc] init];
    application.delegate = delegate;
    
    [NSDocumentController sharedDocumentController];
    
    // init window
    NSRect rect = NSMakeRect(0, 0, 1280, 720);
    NSWindow *mainWindow = [[NSWindow alloc] initWithContentRect:rect styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask backing:NSBackingStoreBuffered defer:YES];
    mainWindow.title = @"OpenLara";
    mainWindow.acceptsMouseMovedEvents = YES;
    mainWindow.delegate = delegate;
    
    // init OpenGL context
    NSOpenGLPixelFormatAttribute attribs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 32,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAStencilSize, 8,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        0
    };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attribs];
    
    OpenLaraGLView *view = [[OpenLaraGLView alloc] initWithFrame:mainWindow.contentLayoutRect pixelFormat:format];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    mainWindow.contentView = view;
    [view.openGLContext makeCurrentContext];
    
    // Init main menu
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appMenu = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenu];
    appMenu.submenu = [[NSMenu alloc] initWithTitle:@""];
    
    // - app menu (no preferences)
    [appMenu.submenu addItemWithTitle:@"About OpenLara" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    
    [appMenu.submenu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *servicesItem = [[NSMenuItem alloc] initWithTitle:@"Services" action:nil keyEquivalent:@""];
    servicesItem.submenu = [[NSMenu alloc] initWithTitle:@""];
    [appMenu.submenu addItem:servicesItem];
    
    [appMenu.submenu addItem:[NSMenuItem separatorItem]];
    
    [appMenu.submenu addItemWithTitle:@"Hide OpenLara" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthersItem = [appMenu.submenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthersItem.keyEquivalentModifierMask = NSAlternateKeyMask | NSCommandKeyMask;
    [appMenu.submenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    
    [appMenu.submenu addItem:[NSMenuItem separatorItem]];
    
    [appMenu.submenu addItemWithTitle:@"Quit OpenLara" action:@selector(terminate:) keyEquivalent:@"q"];
    
    // - file menu
    NSMenuItem *fileMenu = [mainMenu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    fileMenu.submenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu.submenu addItemWithTitle:@"Open…" action:@selector(loadLevel:) keyEquivalent:@"o"];
    NSMenuItem *openRecentMenuItem = [fileMenu.submenu addItemWithTitle:@"Open Recent" action:nil keyEquivalent:@""];
    openRecentMenuItem.submenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    [openRecentMenuItem.submenu setValue:@"NSRecentDocumentsMenu" forKey:@"menuName"];
    
    // - window menu
    NSMenuItem *windowMenu= [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:windowMenu];
    windowMenu.submenu = [[NSMenu alloc] initWithTitle:@"Window"];
    
    [windowMenu.submenu addItemWithTitle:@"Minimize" action:@selector(miniaturize:) keyEquivalent:@"m"];
    [windowMenu.submenu addItemWithTitle:@"Zoom" action:@selector(zoom:) keyEquivalent:@""];
    
    application.mainMenu = mainMenu;
    application.windowsMenu = windowMenu.submenu;
    application.servicesMenu = servicesItem.submenu;

    // get path to game content
    NSBundle *bundle  = [NSBundle mainBundle];
    NSURL *resourceURL  = bundle.resourceURL;
    contentPath = new char[1024];
    [resourceURL getFileSystemRepresentation:contentPath maxLength:1024];
    strcat(contentPath, "/");

    soundInit();
    setupJoystickInput();
    Game::init();
    
    // show window
    [mainWindow center];
    [mainWindow makeKeyAndOrderFront:nil];
    
    // Set up DisplayLink. This will call our callback in time with display
    // refresh rate.
    CVReturn cvreturn = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    if (cvreturn != kCVReturnSuccess) {
        NSLog(@"Could not create Display Link: %d", (int) cvreturn);
    }
    cvreturn = CVDisplayLinkSetOutputCallback(displayLink, displayLinkCallback, view);
    if (cvreturn != kCVReturnSuccess) {
        NSLog(@"Could not create set callback for display link: %d", (int) cvreturn);
    }
    
    lastTime = getTime();
    fpsTime = lastTime + 1000;
    cvreturn = CVDisplayLinkStart(displayLink);
    if (cvreturn != kCVReturnSuccess) {
        NSLog(@"Could not start display link: %d", (int) cvreturn);
    }
    
    // Start application main loop
    [application run];
    return 0;
}
