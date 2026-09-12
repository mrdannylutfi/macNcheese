#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <sys/sysctl.h>

// --- Helper Functions to Fetch Deep Hardware Info ---

// 1. Fetch Apple Silicon or Intel Processor Marketing Name
NSString* GetMacProcessorName() {
    char buffer[128];
    size_t bufferSize = sizeof(buffer);
    if (sysctlbyname("machdep.cpu.brand_string", &buffer, &bufferSize, NULL, 0) == 0) {
        return [NSString stringWithUTF8String:buffer];
    }
    return @"Unknown Processor Architecture";
}

// 2. Fetch Serial Number from the IORegistry
NSString* GetMacSerialNumber() {
    NSString *serial = @"Unknown";
    io_service_t platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (platformExpert) {
        CFTypeRef serialNumberAsCFString = IORegistryEntryCreateCFProperty(platformExpert, CFSTR(kIOPlatformSerialNumberKey), kCFAllocatorDefault, 0);
        if (serialNumberAsCFString) {
            serial = (__bridge NSString *)serialNumberAsCFString;
        }
        IOObjectRelease(platformExpert);
    }
    return serial;
}

// 3. Fetch GPU Names via PCI Devices matching
NSString* GetMacGPUNames() {
    NSMutableArray *gpus = [NSMutableArray array];
    CFMutableDictionaryRef matchDict = IOServiceMatching("IOPCIDevice");
    io_iterator_t iterator;
    
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == kIOReturnSuccess) {
        io_service_t device;
        while ((device = IOIteratorNext(iterator))) {
            CFTypeRef modelRef = IORegistryEntryCreateCFProperty(device, CFSTR("model"), kCFAllocatorDefault, 0);
            if (modelRef) {
                if (CFGetTypeID(modelRef) == CFDataGetTypeID()) {
                    NSData *data = (__bridge NSData *)modelRef;
                    NSString *gpuName = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    gpuName = [gpuName stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]];
                    if (gpuName.length > 0) {
                        [gpus addObject:gpuName];
                    }
                }
                CFRelease(modelRef);
            }
            IOObjectRelease(device);
        }
        IOObjectRelease(iterator);
    }
    // Apple Silicon architectures unify processing on-die
    if (gpus.count == 0) {
        NSString *cpu = GetMacProcessorName();
        if ([cpu containsString:@"Apple"]) {
            return [NSString stringWithFormat:@"%@ Integrated Graphics", cpu];
        }
        return @"Integrated Graphics";
    }
    return [gpus componentsJoinedByString:@", "];
}

// --- Application Delegate ---
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) NSTextField *label;
@property (strong) NSTimer *updateTimer;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSRect frame = NSMakeRect(0, 0, 540, 380);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    
    self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:styleMask backing:NSBackingStoreBuffered defer:NO];
    [self.window setTitle:@"Live Mac System & SoC Telemetry"];
    [self.window center];
    
    self.label = [[NSTextField alloc] initWithFrame:NSMakeRect(25, 20, 490, 320)];
    [self.label setEditable:NO];
    [self.label setSelectable:YES];
    [self.label setBezeled:NO];
    [self.label setDrawsBackground:NO];
    [self.label setFont:[NSFont systemFontOfSize:13]];
    
    [[self.window contentView] addSubview:self.label];
    [self.window makeKeyAndOrderFront:nil];
    
    // Initial display and launch loop updates
    [self updateSystemInfo];
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(updateSystemInfo)
                                                      userInfo:nil
                                                       repeats:YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:self.window];
}

- (void)updateSystemInfo {
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    NSString *osVersion = [processInfo operatingSystemVersionString];
    NSString *hostName = [processInfo hostName];
    NSUInteger cpuCount = [processInfo processorCount];
    unsigned long long physicalMemory = [processInfo physicalMemory] / (1024 * 1024 * 1024);

    NSString *chipTelemetry = GetMacProcessorName();
    NSString *serialNumber = GetMacSerialNumber();
    NSString *gpuNames = GetMacGPUNames();
    
    NSString *powerStatusStr = @"Desktop Mac (No Battery Detected)";
    CFTypeRef powerBlob = IOPSCopyPowerSourcesInfo();
    CFArrayRef powerSourcesList = IOPSCopyPowerSourcesList(powerBlob);
    
    if (powerSourcesList && CFArrayGetCount(powerSourcesList) > 0) {
        CFDictionaryRef powerSourceDesc = IOPSGetPowerSourceDescription(powerBlob, CFArrayGetValueAtIndex(powerSourcesList, 0));
        if (powerSourceDesc) {
            NSString *state = (__bridge NSString *)CFDictionaryGetValue(powerSourceDesc, CFSTR(kIOPSPowerSourceStateKey));
            NSNumber *currentCap = (__bridge NSNumber *)CFDictionaryGetValue(powerSourceDesc, CFSTR(kIOPSCurrentCapacityKey));
            NSNumber *maxCap = (__bridge NSNumber *)CFDictionaryGetValue(powerSourceDesc, CFSTR(kIOPSMaxCapacityKey));
            NSNumber *timeToEmpty = (__bridge NSNumber *)CFDictionaryGetValue(powerSourceDesc, CFSTR(kIOPSTimeToEmptyKey));
            NSNumber *powerRate = (__bridge NSNumber *)CFDictionaryGetValue(powerSourceDesc, CFSTR(kIOPSPowerSourceCurrentKey));
            
            int batteryPercent = (currentCap.intValue * 100) / maxCap.intValue;
            NSString *timeRemainingStr = @"Calculating...";
            if (timeToEmpty && timeToEmpty.intValue > 0) {
                timeRemainingStr = [NSString stringWithFormat:@"%d hr %d min left", timeToEmpty.intValue / 60, timeToEmpty.intValue % 60];
            } else if ([state isEqualToString:@"AC Power"]) {
                timeRemainingStr = @"Connected to wall adapter";
            }

            double watts = ABS(powerRate.doubleValue) / 1000.0;
            NSString *rateDirection = [state isEqualToString:@"AC Power"] ? @"Charging at" : @"Draining at";
            if (powerRate.intValue == 0) {
                rateDirection = @"Idle/Charged";
                watts = 0.0;
            }

            powerStatusStr = [NSString stringWithFormat:
                               @"Source: %@\n"
                               @"  • Charge Level: %d%%\n"
                               @"  • Current Rate: %@ %.2f Watts\n"
                               @"  • Timing Status: %@", 
                               state, batteryPercent, rateDirection, watts, timeRemainingStr];
        }
    }
    
    if (powerSourcesList) CFRelease(powerSourcesList);
    if (powerBlob) CFRelease(powerBlob);

    NSString *propertiesText = [NSString stringWithFormat:
                                @"🖥️  Advanced Mac System Properties\n\n"
                                @"• Host Name: %@\n"
                                @"• OS Version: %@\n"
                                @"• Processor SoC: %@\n"
                                @"• CPU Cores: %lu\n"
                                @"• Physical Memory: %llu GB\n"
                                @"• Serial Number: %@\n"
                                @"• Active GPU(s): %@\n\n"
                                @"🔋 Live Power Metrics:\n%@",
                                hostName, osVersion, chipTelemetry, (unsigned long)cpuCount, physicalMemory, serialNumber, gpuNames, powerStatusStr];

    [self.label setStringValue:propertiesText];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.updateTimer invalidate];
    [NSApp terminate:nil];
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
