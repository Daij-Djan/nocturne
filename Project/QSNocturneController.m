#import "QSNocturneController.h"
#import "CGSPrivate.h"
#import "QSCIFilterWindow.h"
#import "NSWindow+Sticky.h"
#import "PTHotKeyLib.h"
#import "SRCommon.h"
#import "NSStatusItem+Window.h"

#import <stdio.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <ApplicationServices/ApplicationServices.h>

//default keys
#define GlobalHotkeyName @"hotkey"
#define GlobalHotkeyKeyPath @"values.hotkey"
#define AppleInterfaceStyleName @"AppleInterfaceStyle"
#define AppleInterfaceStyleKeyPath @"values.AppleInterfaceStyle"

@implementation QSNocturneController {
  CGGammaValue gOriginalRedTable[ 256 ];
  CGGammaValue gOriginalGreenTable[ 256 ];
  CGGammaValue gOriginalBlueTable[ 256 ];
  NSMutableArray *desktopWindows;
  NSMutableArray *overlayWindows;
  IBOutlet NSWindow *prefsWindow;
  IBOutlet NSMenu *statusMenu;
  BOOL shouldQuit;

  BOOL enabled;

  NSColor *whiteColor;
  NSColor *blackColor;
  NSStatusItem *statusItem;
  float originalBrightness;
  QSLMUMonitor *monitor;


  NSWindow *menuWindow;
  QSCIFilterWindow *menuHueOverlay;
  QSCIFilterWindow *menuInvertOverlay;
  NSArray *windows;
  BOOL trackingMenu;
  BOOL visible;
  BOOL shouldHide;
  BOOL correctHue;
  BOOL dimMenu;
}

//setup settings
+ (void)initialize {
  id defaults = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSUserDefaults"];
  [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
  [NSColorPanel setPickerMode:NSHSBModeColorPanel];
}

//kvo dependencies
+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
  if([key isEqualToString:@"enabled"]) {
    return [NSSet setWithObjects:@"toggleButtonTitle", @"toggleButtonImage", nil];
  }
  else if([key isEqualToString:@"toggleButtonTitle"]) {
    return [NSSet setWithObject:@"enabled"];
  }
  else if([key isEqualToString:@"toggleButtonImage"]) {
    return [NSSet setWithObject:@"enabled"];
  }
  else if([key isEqualToString:@"useLightSensors"]) {
    return [NSSet setWithObject:@"lightMonitor"];
  }
  else if([key isEqualToString:@"lightMonitor"]) {
    return [NSSet setWithObject:@"useLightSensors"];
  }
  return nil;
}

#pragma mark - NSApplicationDelegate

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  [self toggleMode:nil];
  [sender hide:sender];
  return NO;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
  //before we change anything
  uint32_t sampleCount;
  CGGetDisplayTransferByTable( 0, 256, gOriginalRedTable, gOriginalGreenTable, gOriginalBlueTable, &sampleCount);
  originalBrightness = [self getDisplayBrightness];
  
  //add menubar icon
  BOOL uiElement = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"LSUIElement"] boolValue];
  if (uiElement) {
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:22];
    [statusItem setMenu:statusMenu];
    [statusItem setHighlightMode:YES];
    [self applyMenubarIcon];

    //observe defaults for dark mode
    [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:AppleInterfaceStyleKeyPath options:0 context: NULL];
  }

  //prepare our arrays for the overlay windows
  if (overlayWindows == NULL) {
    overlayWindows = [[NSMutableArray alloc] init];
  }
  if (desktopWindows == NULL) {
    desktopWindows = [[NSMutableArray alloc] init];
  }
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)aNotification{
  if (!enabled) return;
  
  if ([overlayWindows count] != 0) {
    [self setupOverlays];
  }
  [self updateGamma];
  if ([desktopWindows count] != 0) {
    [self setDesktopHidden:YES];
  }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  //apply hotkey
  [self applyHotkey];
  
  //observe defaults for hotkey
  [[NSUserDefaultsController sharedUserDefaultsController]
   addObserver:self forKeyPath:GlobalHotkeyKeyPath options:0 context: NULL];
  
  NSNumber *enabledValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"enabled"];
  [self setEnabled: [enabledValue boolValue]];
  
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDate *lastLaunch = [defaults objectForKey:@"lastLaunchDate"];
  if (!lastLaunch) {
    [self showPreferences:self];
    [defaults setValue:[NSDate date] forKey:@"lastLaunchDate"];
  }
}

- (void)applicationWillTerminate:(NSNotification *)notification{
  [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"enabled"];
  shouldQuit = YES;
  [self setEnabled:NO];
}

#pragma mark - IBActions

- (IBAction)showPreferences:(id)sender {
  //position the prefs
  NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
  NSRect windowFrame = [prefsWindow frame];
  windowFrame = NSOffsetRect(windowFrame, NSMaxX(screenFrame) - NSMaxX(windowFrame) - 20, NSMaxY(screenFrame) - NSMaxY(windowFrame) - 20);
  [prefsWindow setFrame:windowFrame display:YES animate:YES ];
  
  //show the window
  [NSApp activateIgnoringOtherApps:YES];
  [prefsWindow makeKeyAndOrderFront:self];
  [prefsWindow display];
}

- (IBAction)toggleMode:(id)sender {
  [self performSelector:@selector(toggle) withObject:nil afterDelay:0.0];
}

- (IBAction)changeHotkey:(id)sender {
  id hotkey = [[PTHotKeyCenter sharedCenter] hotKeyForName:GlobalHotkeyName];
  [[PTKeyComboPanel sharedPanel] showSheetForHotkey:hotkey forWindow:prefsWindow modalDelegate:self];
}

- (IBAction)resetTint:(id)sender {
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"whiteColor"];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"blackColor"];
}

#pragma mark - Bindings

- (BOOL)canUseSensors {
  return [QSLMUMonitor hasSensors];
}

- (BOOL)useLightSensors {
  return monitor != nil; 
}

- (void)setUseLightSensors:(BOOL)value {
  if (value) {
    if (!monitor) {
      monitor = [[QSLMUMonitor alloc] init];
      [monitor setDelegate:self];
      [monitor setMonitorSensors:YES];
      NSUserDefaultsController *dController = [NSUserDefaultsController sharedUserDefaultsController];
      
      [monitor bind:@"lowerBound" toObject:dController withKeyPath:@"values.lowerLightValue" options:nil];
      [monitor bind:@"upperBound" toObject:dController withKeyPath:@"values.upperLightValue" options:nil];      
    }
  } else {
    [monitor unbind:@"lowerBound"];
    [monitor unbind:@"upperBound"];
    
    [monitor setMonitorSensors:NO];
    monitor = nil;
  }
}

- (QSLMUMonitor *)lightMonitor {
  return monitor;
}

- (id)valueForUndefinedKey:(NSString *)key{
  return nil;
}
- (void)toggle {
  [self setEnabled:![self enabled]];
}

- (void)setDesktopHidden:(BOOL)hidden {
  NSWindow *desktopWindow;
  [desktopWindows removeAllObjects];
  
  if (hidden) {
    for (int i = 0; i < [[NSScreen screens] count]; ++i) {
      desktopWindow = [[NSWindow alloc] initWithContentRect:[[[NSScreen screens] objectAtIndex:i] frame]
                                                  styleMask:NSBorderlessWindowMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
      
      [desktopWindow setHidesOnDeactivate:NO];
      [desktopWindow setCanHide:NO];
      [desktopWindow setIgnoresMouseEvents:YES];
      [desktopWindow setLevel:NSNormalWindowLevel - 1];
      [desktopWindow setBackgroundColor:[NSColor colorWithDeviceWhite:1.0 alpha:1.0]];
      [desktopWindow orderFront:nil];
      [desktopWindow setSticky:YES];
      [desktopWindow setCollectionBehavior:1 | 16];
      [desktopWindows addObject:desktopWindow];
    }
  }
}




- (float)getDisplayBrightness {
  CGDisplayErr      dErr;
  io_service_t      service;
  CGDirectDisplayID targetDisplay;
  
  CFStringRef key = CFSTR(kIODisplayBrightnessKey);
  
  targetDisplay = CGMainDisplayID();
  service = CGDisplayIOServicePort(targetDisplay);
  
  float brightness = 1.0;
  dErr = IODisplayGetFloatParameter(service, kNilOptions, key, &brightness);
  
  if (dErr == kIOReturnSuccess) {
    return brightness;
  } else {
    return 1.0;
  }
}

- (void)setDisplayBrightness:(float)brightness {
  CGDisplayErr      dErr;
  io_service_t      service;
  CGDirectDisplayID targetDisplay;
  
  CFStringRef key = CFSTR(kIODisplayBrightnessKey);
  
  targetDisplay = CGMainDisplayID();
  service = CGDisplayIOServicePort(targetDisplay);
  
  if (brightness != HUGE_VALF) { // set the brightness, if requested
    dErr = IODisplaySetFloatParameter(service, kNilOptions, key, brightness);
  }
}


#define PROGNAME "display-brightness"
- (void)setBrightness:(float)brightness {
  BOOL adjust = [[NSUserDefaults standardUserDefaults] boolForKey:@"adjustBrightness"];
  if (!adjust) brightness = originalBrightness;
  if (brightness == 0.0) brightness = 0.005;
  [self setDisplayBrightness:brightness];
}

- (void)setAdjustBrightness:(BOOL)value {
  float brightness = [[NSUserDefaults standardUserDefaults] floatForKey:@"brightness"];
  [self setBrightness:brightness];
}

- (void)restoreGamma {
  CGDisplayRestoreColorSyncSettings(); 
}

- (void)setGammaEnabled:(BOOL)enabled {
  [self updateGamma];
}

- (void)updateGamma {
  if (![[NSUserDefaults standardUserDefaults] boolForKey:@"gammaEnabled"] || !(whiteColor || blackColor)) {
    [self restoreGamma];
    return;
  }
  
  NSColor *whitepoint = [whiteColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  NSColor *blackpoint = [blackColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  
  CGGammaValue redTable[ 256 ];
  CGGammaValue greenTable[ 256 ];
  CGGammaValue blueTable[ 256 ];
  CGDisplayErr cgErr;
  
  float maxR = whitepoint ? [whitepoint redComponent] : 1.0;
  float maxG = whitepoint ? [whitepoint greenComponent] : 1.0;
  float maxB = whitepoint ? [whitepoint blueComponent] : 1.0;
  
  float minR = blackpoint ? [blackpoint redComponent] : 0.0;
  float minG = blackpoint ? [blackpoint greenComponent] : 0.0;
  float minB = blackpoint ? [blackpoint blueComponent] : 0.0;
  
  
  if (fabs(maxR-minR) + fabs(maxG-minG) + fabs(maxB-minB) < 0.1) {
    //NSLog(@"adjusting colors to protect %f", fabs(maxR-minR) + fabs(maxG-minG) + fabs(maxB-minB));
    maxR += 0.1;
    maxB += 0.1;
    maxG += 0.1;
    minR -= 0.1;
    minB -= 0.1;
    minG -= 0.1;
  }
  
  for (int i = 0; i < 256 ; i++) {
    redTable[ i ] =  minR +  (maxR - minR) * gOriginalRedTable[ i ];
    greenTable[ i ] = minG + (maxG - minG) * gOriginalGreenTable[ i ];
    blueTable[ i ] = minB + (maxB - minG) * gOriginalBlueTable[ i ];
  }
  
  //get the number of displays
  CGDisplayCount numDisplays;
  CGGetActiveDisplayList(0, NULL, &numDisplays);
  
  //set the gamma on each display
  CGDirectDisplayID displays[numDisplays];
  CGGetActiveDisplayList(numDisplays, displays, NULL);
  for (int i = 0; i < 10; ++i) {
    cgErr = CGSetDisplayTransferByTable(displays[i], 256, redTable, greenTable, blueTable);
  }
}

- (void)setInverted:(BOOL)value{
  CGDisplaySetInvertedPolarity(value);
  //  NSRect screenFrame = [[NSScreen mainScreen] frame];
  //  NSRect cornerFrame1 = NSMakeRect(NSMinX(screenFrame), NSMaxY(screenFrame) - 8, 8, 8);
  //  NSRect cornerFrame2 = NSMakeRect(NSMaxX(screenFrame) - 8, NSMaxY(screenFrame) - 8, 8, 8);
  //  
  //  if (value) {
  //    NSWindow *cornerWindow1 = [[NSWindow alloc] initWithContentRect:cornerFrame1
  //                                                          styleMask:NSBorderlessWindowMask
  //                                                            backing:NSBackingStoreBuffered
  //                                                              defer:NO];
  //    NSWindow *cornerWindow2 = [[NSWindow alloc] initWithContentRect:cornerFrame2
  //                                                          styleMask:NSBorderlessWindowMask
  //                                                            backing:NSBackingStoreBuffered
  //                                                              defer:NO];
  //    [cornerWindow1 orderFront:nil];
  //    [cornerWindow1 setLevel:NSStatusWindowLevel+1];
  //    [cornerWindow2 orderFront:nil];
  //    [cornerWindow2 setLevel:NSStatusWindowLevel+1];
  //
  //  }
}

- (void)setMonochrome:(BOOL)value{
  CGDisplayForceToGray(value);  
}

- (void)setHueAngle:(float)hue {
	if (hue == 0) {
		[self removeOverlays];
	} else {
		[self setupOverlays];
	}    
}

- (void)removeOverlays{
	while([overlayWindows count] > 0) {
		QSCIFilterWindow *overlayWindow = [overlayWindows lastObject];
		[overlayWindows removeLastObject];
		overlayWindow = nil;
	}
}

- (void)setupOverlays{
	for (int i = 0; i < [[NSScreen screens] count]; ++i) {
		QSCIFilterWindow *overlayWindow;
		if ([overlayWindows count] <= i) {
			overlayWindow = [[QSCIFilterWindow alloc] init];
			[overlayWindow setLevel:kCGMaximumWindowLevel];
			[overlayWindow setFilter:@"CIHueAdjust"];
			[overlayWindow setFilterValues:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithFloat:M_PI], @"inputAngle",nil]];
			[overlayWindow orderFront:nil];
      [overlayWindow setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
			[overlayWindows addObject:overlayWindow];
		} else {
			overlayWindow = [overlayWindows objectAtIndex:i];
		}
		[overlayWindow setFrame:[[[NSScreen screens] objectAtIndex:i] frame] display:NO];
	}
	while ([overlayWindows count] > [[NSScreen screens] count]) {
		QSCIFilterWindow *overlayWindow = [overlayWindows lastObject];
		[overlayWindows removeLastObject];
		overlayWindow = nil;
	}
}	

- (void)setHueCorrect:(BOOL)value{
  [self setHueAngle: value ? M_PI : 0];
}


#define kCGSDebugOptionNormal 0
#define kCGSDebugOptionNoShadows 16384
- (void)setShadowsHidden:(BOOL)value{
  CGSSetDebugOptions(value ? kCGSDebugOptionNoShadows : kCGSDebugOptionNormal);
}


- (BOOL)enabled {
  return enabled;
}

- (void)applyEnabled:(BOOL)value {
  
  if (statusItem) [[statusItem _window] display];

  [menuWindow setBackgroundColor:(enabled ? [NSColor whiteColor] : [NSColor blackColor])];
  [self updateFrames];
  
  if (enabled) { 
    originalBrightness = [self getDisplayBrightness];
    
    NSUserDefaultsController *dController = [NSUserDefaultsController sharedUserDefaultsController];
    
    [self bind:@"inverted" toObject:dController withKeyPath:@"values.inverted" options:nil];
    [self bind:@"hueCorrect" toObject:dController withKeyPath:@"values.hueCorrect" options:nil];
    [self bind:@"shadowsHidden" toObject:dController withKeyPath:@"values.shadowsHidden" options:nil];
    [self bind:@"desktopHidden" toObject:dController withKeyPath:@"values.desktopHidden" options:nil];
    [self bind:@"monochrome" toObject:dController withKeyPath:@"values.monochrome" options:nil];
    [self bind:@"gammaEnabled" toObject:dController withKeyPath:@"values.gammaEnabled" options:nil];
    [self bind:@"brightness" toObject:dController withKeyPath:@"values.brightness" options:nil];
    [self bind:@"adjustBrightness" toObject:dController withKeyPath:@"values.adjustBrightness" options:nil];
    [self bind:@"whiteColor" toObject:dController withKeyPath:@"values.whiteColor"
       options:[NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName forKey:NSValueTransformerNameBindingOption]];
    [self bind:@"blackColor" toObject:dController withKeyPath:@"values.blackColor"
       options:[NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName forKey:NSValueTransformerNameBindingOption]];
    
  } else { 
    [self unbind:@"inverted"];
    [self unbind:@"hueCorrect"];
    [self unbind:@"shadowsHidden"];
    [self unbind:@"desktopHidden"];
    [self unbind:@"monochrome"];
    [self unbind:@"gammaEnabled"];
    [self unbind:@"adjustBrightness"];
    [self unbind:@"brightness"];
    [self unbind:@"whiteColor"];
    [self unbind:@"blackColor"];
    
    CGDisplayRestoreColorSyncSettings();
    [self setInverted:NO];
    [self setHueCorrect:NO];
    [self setMonochrome:NO];
    [self setShadowsHidden:NO];
    [self setDesktopHidden:NO];
    [self setDisplayBrightness:fmax(0.005, originalBrightness)];
  }
  


  if (shouldQuit) {
    [prefsWindow orderOut:nil];
    [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
    statusItem = nil;
  }
  [self willChangeValueForKey:@"toggleButtonTitle"];
  [self didChangeValueForKey:@"toggleButtonTitle"];
  [self willChangeValueForKey:@"toggleButtonImage"];
  [self didChangeValueForKey:@"toggleButtonImage"];
  [prefsWindow display];
}

- (void)applyEnabled:(BOOL)value withFade:(BOOL)fade {
  if (!fade) {
    [self applyEnabled:value]; 
  } else { 
    
    float fadeout = 0.5;
    float fadein = 0.5;
    CGDisplayFadeReservationToken token;
    CGDisplayErr err;
    err = CGAcquireDisplayFadeReservation (3.0, &token); // 1
    if (err == kCGErrorSuccess) {
      err = CGDisplayFade (token, 0.25, kCGDisplayBlendNormal,
                           kCGDisplayBlendSolidColor, fadeout, fadeout, fadeout, true); // 2
      // Your code to change the display mode and
      // set the full-screen context.
      @try {
        [self applyEnabled:value];
        //   [prefsWindow makeKeyAndOrderFront:nil];  
      }
      @catch (NSException *e) {
        NSLog(@"Error %@", e); 
      }
      
      err = CGDisplayFade (token, 0.75, kCGDisplayBlendSolidColor,
                           kCGDisplayBlendNormal, fadein, fadein, fadein, true); // 3
      err = CGReleaseDisplayFadeReservation (token); // 4
    }
    
  }
}

- (void)setEnabled:(BOOL)value {
  if (enabled != value) {
    enabled = value;
    [self applyEnabled:value withFade:YES];
  }
}

- (NSColor *)whiteColor {
  return whiteColor;
}

- (void)setWhiteColor:(NSColor *)value {
  if (whiteColor != value) {
    whiteColor = [value copy];
    [self updateGamma];
  }
}

- (NSColor *)blackColor {
  return blackColor;
}

- (void)setBlackColor:(NSColor *)value {
  if (blackColor != value) {
    blackColor = [value copy];
    [self updateGamma];
    
  }
}

#pragma mark - QSNocturneController (MenuCovers)

pascal OSStatus AppEventHandler( EventHandlerCallRef inCallRef, EventRef inEvent, void* controller );
pascal OSStatus AppEventHandler( EventHandlerCallRef inCallRef, EventRef inEvent, void* controller ) {
  OSStatus status = eventNotHandledErr;
  
  if (GetEventClass(inEvent) == kEventClassApplication) {
    UInt32 mode = 0;
    (void) GetEventParameter(inEvent,
                             kEventParamSystemUIMode,
                             typeUInt32,
                             /*outActualType*/ NULL,
                             sizeof(UInt32),
                             /*outActualSize*/ NULL,
                             &mode);
    [(__bridge QSNocturneController*)controller modeDidChange:mode];
    status = noErr;	 // everything went well, event handled
  }
  return status;
}

- (void)modeDidChange:(int)mode {
  if (mode) {
    [menuWindow orderOut:nil];
    [menuHueOverlay orderOut:nil];
    [menuInvertOverlay orderOut:nil];
  } else {
    if (dimMenu) [menuWindow orderFront:nil];
    [menuHueOverlay orderFront:nil];
    [menuInvertOverlay orderFront:nil];
  }
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  if ([keyPath isEqualToString:@"values.dimMenuOpacity"]) {
    CGFloat dimMenuMin = [[NSUserDefaults standardUserDefaults] floatForKey:@"dimMenuOpacity"];
    [menuWindow setAlphaValue:1.0 - dimMenuMin];  
  } else if ([keyPath isEqualToString:@"values.hueCorrect"]) {
    correctHue = [[object valueForKeyPath:keyPath] boolValue];
    [self updateFrames];
  } else if([keyPath isEqualToString:GlobalHotkeyKeyPath]) {
    [self applyHotkey];
  } else if([keyPath isEqualToString:AppleInterfaceStyleKeyPath]) {
    [self applyMenubarIcon];
  }
  else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
  
  NSLog(@"blah");
}

- (NSArray *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window {
  NSLog(@"blah");
  return nil;
}


- (void)workspaceChanged:(NSNotification *)notif {
  int currentSpace;
  // get an array of all the windows in the current Space
  CFArrayRef windowsInSpace = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListOptionOnScreenOnly, kCGNullWindowID);      
  
  // now loop over the array looking for a window with the kCGWindowWorkspace key
  for (NSMutableDictionary *thisWindow in (NSArray *)CFBridgingRelease(windowsInSpace))
  {
    if ([thisWindow objectForKey:(id)kCGWindowWorkspace])
    {
      currentSpace = [[thisWindow objectForKey:(id)kCGWindowWorkspace] intValue];
      break;
    }
  }
}

- (void)awakeFromNib{
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(workspaceChanged:) name:NSWorkspaceActiveSpaceDidChangeNotification  object:nil];
  [prefsWindow setBackgroundColor:[NSColor whiteColor]];   
  [prefsWindow setLevel:NSFloatingWindowLevel];   
  [prefsWindow setHidesOnDeactivate:NO];   
  
  correctHue = [[NSUserDefaults standardUserDefaults] boolForKey:@"hueCorrect"];
  
  NSUserDefaultsController *dController = [NSUserDefaultsController sharedUserDefaultsController];
  [self bind:@"dimMenu" toObject:dController withKeyPath:@"values.dimMenu" options:nil];
  [self bind:@"useLightSensors" toObject:dController withKeyPath:@"values.useLightSensors" options:nil];
  [dController addObserver:self forKeyPath:@"values.dimMenuOpacity" options:0 context:NULL];
  [dController addObserver:self forKeyPath:@"values.hueCorrect" options:0 context:NULL];
  
  NSRect rect = [[NSScreen mainScreen] frame];
  rect = NSMakeRect(0,NSMaxY(rect)-22,NSWidth(rect),22);
  
  menuWindow = [[NSWindow alloc]initWithContentRect:rect styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
  [menuWindow setBackgroundColor:(enabled ? [NSColor whiteColor] : [NSColor blackColor])];
  [menuWindow setOpaque:NO];
  [menuWindow setAlphaValue:0.9];
  [menuWindow setCanHide:NO];
  [menuWindow setAllowsToolTipsWhenApplicationIsInactive:YES];
  [menuWindow setIgnoresMouseEvents:YES];
  [menuWindow setHasShadow:NO];
  [menuWindow setDelegate:self];
  [menuWindow setLevel:kCGStatusWindowLevel+2];
  [menuWindow setCollectionBehavior: NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle];
//  [menuWindow setSticky:YES];
  //[window setDelegate:[window contentView]]];
  NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect | NSTrackingEnabledDuringMouseDrag |NSTrackingActiveAlways
                                                         owner:self userInfo:nil];
  [[menuWindow contentView] addTrackingArea:area];
  
  [menuWindow setAlphaValue:0.0];
  
  [self createOverlays];

  
  [[NSAnimationContext currentContext] setDuration:1.0];
  [[menuWindow animator] setAlphaValue:1.0];  
  //[QSBatteryDotView openDotWindows];
  
  [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(updateFrames) name:NSApplicationDidChangeScreenParametersNotification object:nil];
  
  
  static const EventTypeSpec sAppEvents[] = { { kEventClassApplication, kEventAppSystemUIModeChanged } };
  
  InstallApplicationEventHandler( NewEventHandlerUPP( (void*)AppEventHandler ),
                                 GetEventTypeCount( sAppEvents ),
                                 sAppEvents, (__bridge  void*)self, NULL );
}

- (void)endTracking {
  trackingMenu = FALSE;  
  if (shouldHide) [self hide];
}

- (void)beginTracking {
  trackingMenu = TRUE;  
}

- (void)updateFrames {
  CGFloat menuHeight = enabled ? 22 : 21;
  NSRect frame = [[NSScreen mainScreen] frame];
  frame.origin.y = NSHeight(frame) - menuHeight;
  frame.size.height = menuHeight;
  
  [menuWindow setFrame:frame display:NO];
  
  NSRect overlayFrame = frame;

  if ([self enabled]) {
    overlayFrame.size.height = 1;
  }
  
  [menuHueOverlay setFrame:overlayFrame display:NO];
  [menuInvertOverlay setFrame:overlayFrame display:NO];
  
  if (dimMenu) {
    [menuWindow orderFront:nil];
  } else {
    [menuWindow orderOut:nil];
  }
  
  if ([self enabled]) {
    [menuInvertOverlay orderFront:nil];
  } else {
    [menuInvertOverlay orderOut:nil];
  }
  
  if (correctHue && [menuInvertOverlay isVisible]) {
    [menuHueOverlay orderFront:nil]; 
  } else {
    [menuHueOverlay orderOut:nil];
  }
}

- (void)createOverlays {
  menuHueOverlay = [[QSCIFilterWindow alloc] init];
  [menuHueOverlay setLevel:kCGStatusWindowLevel+1];
  [menuHueOverlay setFilter:@"CIHueAdjust"];
  [menuHueOverlay setFilterValues:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithFloat:M_PI], @"inputAngle",nil]];  
  [menuHueOverlay setCollectionBehavior:NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle];
  [menuHueOverlay setSticky:YES];

  menuInvertOverlay = [[QSCIFilterWindow alloc] init];
  [menuInvertOverlay setLevel:kCGStatusWindowLevel+1];
  [menuInvertOverlay setFilter:@"CIColorInvert"];
  [menuInvertOverlay setCollectionBehavior:NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle];
  [menuInvertOverlay setSticky:YES];

  [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(endTracking) name:@"com.apple.HIToolbox.endMenuTrackingNotification" object:nil];
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(beginTracking) name:@"com.apple.HIToolbox.beginMenuTrackingNotification" object:nil];
  
  windows = [NSArray arrayWithObjects:menuWindow, menuHueOverlay, menuInvertOverlay, nil]; 
  [self updateFrames];
}

- (void)hide {
  CGFloat dimMenuMin = [[NSUserDefaults standardUserDefaults] floatForKey:@"dimMenuOpacity"];
  CGFloat dimMenuDuration = [[NSUserDefaults standardUserDefaults] floatForKey:@"dimMenuDuration"];
  visible = NO;
  [[NSAnimationContext currentContext] setDuration:dimMenuDuration];
  [[menuWindow animator] setAlphaValue:1.0 - dimMenuMin];  
}

- (void)show {
  CGFloat dimMenuMax = [[NSUserDefaults standardUserDefaults] floatForKey:@"undimMenuOpacity"];
  CGFloat undimMenuDuration = [[NSUserDefaults standardUserDefaults] floatForKey:@"undimMenuDuration"];
  visible = YES;
  [[NSAnimationContext currentContext] setDuration:undimMenuDuration];
  [[menuWindow animator] setAlphaValue:1.0 - dimMenuMax]; 
}

- (void)mouseEntered:(NSEvent *)theEvent {
  [self show];
  shouldHide = NO;
}
- (void)mouseExited:(NSEvent *)theEvent {
  if (!trackingMenu) [self hide];  
  else shouldHide = YES;
}

- (void)setDimMenu:(BOOL)flag {
  dimMenu = flag;
  [self updateFrames];
}

#pragma mark image & title for toggle button / menuitem

- (NSString *)toggleButtonTitle {
  NSString *title = enabled ? @"Switch to Day" : @"Switch to Night";

  //get key combo
  id plistTool = [[NSUserDefaults standardUserDefaults] objectForKey:GlobalHotkeyName];
  PTKeyCombo *kc = [[PTKeyCombo alloc] initWithPlistRepresentation:plistTool];
  if(kc) {
    title = [title stringByAppendingFormat:@" (%@)", kc];
  }
  return title;
}
- (NSImage *)toggleButtonImage {
  return enabled ? [NSImage imageNamed:@"Sun"] : [NSImage imageNamed:@"Moon"];
}


#pragma mark - menubar icon

- (void)applyMenubarIcon {
  NSString *osxMode = [[NSUserDefaults standardUserDefaults] stringForKey:AppleInterfaceStyleName];
  if([osxMode isEqualToString:@"Dark"]) {
    [statusItem setImage:[NSImage imageNamed:@"NocturneMenuPressed"]];
    [statusItem setAlternateImage:[NSImage imageNamed:@"NocturneMenu"]];
  }
  else {
    [statusItem setImage:[NSImage imageNamed:@"NocturneMenu"]];
    [statusItem setAlternateImage:[NSImage imageNamed:@"NocturneMenuPressed"]];
  }
}

#pragma mark - hotkey handling

- (void)keyComboPanelEnded:(PTKeyComboPanel*)panel {
  [[NSUserDefaults standardUserDefaults] setObject:[[panel keyCombo] plistRepresentation] forKey:GlobalHotkeyName];
  [self willChangeValueForKey:@"toggleButtonTitle"];
  [self didChangeValueForKey:@"toggleButtonTitle"];
}

- (void)applyHotkey {
	//unregister old
	for (PTHotKey *hotkey in [[PTHotKeyCenter sharedCenter] allHotKeys]) {
		[[PTHotKeyCenter sharedCenter] unregisterHotKey:hotkey];
	}
  
	//read plist
	id plistTool = [[NSUserDefaults standardUserDefaults] objectForKey:GlobalHotkeyName];
  
  //get key combo
  PTKeyCombo *kc = [[PTKeyCombo alloc] initWithPlistRepresentation:plistTool];
  
  //register it
  PTHotKey *hotKey = [[PTHotKey alloc] init];
  hotKey.name = GlobalHotkeyName;
  hotKey.keyCombo = kc;
  hotKey.target = self;
  hotKey.action = @selector(hitHotKey:);
  [[PTHotKeyCenter sharedCenter] registerHotKey:hotKey];
}

- (void)hitHotKey:(id)sender {
  [self toggle];
}

#pragma mark - QSLMNUMonitorDelegate

- (void)monitor:(QSLMUMonitor *)monitor passedLowerBound:(uint64_t)lowerBound withValue:(uint64_t)value {
  [self setEnabled:YES];
}

- (void)monitor:(QSLMUMonitor *)monitor passedUpperBound:(uint64_t)upperBound withValue:(uint64_t)value {
  [self setEnabled:NO];
}

@end

