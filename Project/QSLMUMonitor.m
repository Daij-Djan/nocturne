//
//  QSLMUMonitor.m
//  Nocturne
//
//  Created by Dominik Pich 11/2013
/**
 * based loosly on code:
 * Created by Nicholas Jitkoff on 5/14/07.
 * Copyright 2007 Blacktree. All rights reserved.
*/
#import "QSLMUMonitor.h"
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

#ifndef LMUCOMMON_H
#define LMUCOMMON_H
enum {
    kGetSensorReadingID   = 0,  // getSensorReading(int *, int *)
    kGetLEDBrightnessID   = 1,  // getLEDBrightness(int, int *)
    kSetLEDBrightnessID   = 2,  // setLEDBrightness(int, int, int *)
    kSetLEDFadeID         = 3,  // setLEDFade(int, int, int, int *)
    
    // other firmware-related functions
    // verifyFirmwareID     = 4,  // verifyFirmware(int *)
    // getFirmwareVersionID = 5,  // getFirmwareVersion(int *)
    
    // other flashing-related functions
    // ...
};
#endif

@implementation QSLMUMonitor {
    NSTimer *checkTimer;
    io_connect_t dataPort;
    CGFloat percent;
    CGFloat _pollFrequency;
}

- (NSNumber*)percent {
    return @(percent);
}

- (void)checkValues:(NSTimer *)timer {
    [self willChangeValueForKey:@"percent"];
    
    CGFloat newPercent = [self sensorPercentageValue];
    if(newPercent == -1) {
        return;
    
    }
    //tell delegate
    if (newPercent != percent) {
        if (newPercent < _lowerBound && (percent >= _lowerBound || percent == -1)) {
            [_delegate monitor:self passedLowerBound:_lowerBound withValue:newPercent];
        }
        if (newPercent > _upperBound && (percent <= _upperBound || percent == -1)) {
            [_delegate monitor:self passedUpperBound:_upperBound withValue:newPercent];
        }
    }
    
    percent = newPercent;
    [self didChangeValueForKey:@"percent"];
}

#define kGetSensorMaxValue 12 //dont know if this is ok .. dont even know if LMU is linear or logarithmic or whatever. I apply a logarithmus and accept values till 13

- (CGFloat)sensorPercentageValue {
    CGFloat percentage = -1;
    
    //Get the ALS reading
    uint32_t scalarOutputCount = 2;
    uint64_t values[scalarOutputCount];
    
    kern_return_t kr = IOConnectCallMethod(dataPort,
                                           kGetSensorReadingID,
                                           nil,
                                           0,
                                           nil,
                                           0,
                                           values,
                                           &scalarOutputCount,
                                           nil,
                                           0);
//    NSLog(@"kr %x", kr);
    
    if (kr == KERN_SUCCESS && scalarOutputCount >= 2) {
        double newLeft = log2(values[0]);
        double newRight = log2(values[1]);
        
        double newAvg = (newLeft + newRight) / 2;
        percentage = 100.0 * (CGFloat)(newAvg-kGetSensorMaxValue) / kGetSensorMaxValue;
        
//        NSLog(@"%f + %f / 2 = %f = %f", newLeft, newRight, newAvg, percentage);
    }
    else if(kr == kIOReturnBusy) {
        NSLog(@"kIOReturnBusy");
    }
    else {
        mach_error("I/O Kit error:", kr);
    }
    
    return percentage;
}


- (id) init {
    self = [super init];
    if (self != nil) {
        percent = -1;
        
        //get service
        io_service_t serviceObject = [self.class copySensorService];
        if (!serviceObject) {
            fprintf(stderr, "failed to find ambient light sensor\n");
            return nil;
        }
        
        // Create a connection to the IOService object
        kern_return_t kr = IOServiceOpen(serviceObject, mach_task_self(), 0, &dataPort);
        IOObjectRelease(serviceObject);
        if (kr != KERN_SUCCESS) {
            mach_error("IOServiceOpen:", kr);
            [self setMonitorSensors:NO];
        }
        else {
            [self setMonitorSensors:YES];
        }
    }
    return self;
}

- (void) removeTimer {
    [checkTimer invalidate];
    checkTimer = nil;
}

- (void) scheduleTimerWithInterval:(float)interval {
    [self removeTimer];
    checkTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                  target:self
                                                selector:@selector(checkValues:)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void) setMonitorSensors:(BOOL)flag {
    if (flag) {
        if (!checkTimer) {
            [self scheduleTimerWithInterval:self.pollFrequency];
            if(_delegate && (_lowerBound || _upperBound)) {
                [self checkValues:nil];
            }
        }
    } else {
        [self removeTimer];
    }
    percent = -1;
}

- (NSTimeInterval)pollFrequency {
    if(_pollFrequency==0) {
        _pollFrequency=3.0; //default secs
    }
    return _pollFrequency;
}
- (void)setPollFrequency:(NSTimeInterval)pollFrequency {
    [self removeTimer];
    self.monitorSensors = self.monitorSensors;
}

- (void)setLowerBound:(uint64_t)lowerBound {
    percent = -1;
    _lowerBound = lowerBound;
}

- (void)setUpperBound:(uint64_t)upperBound {
    percent = -1;
    _upperBound = upperBound;
}

- (void) dealloc {
    [self removeTimer];
    
    if(dataPort) {
        IOServiceClose(dataPort);
    }
}

#pragma mark -

+ (BOOL)hasSensors {
    io_service_t serviceObject = [self copySensorService];
    if (serviceObject) {
        IOObjectRelease(serviceObject);
        return YES;
    }
    return NO;
}

+ (io_service_t)copySensorService {
    
    // Look up a registered IOService object whose class is AppleLMUController
    io_service_t serviceObject = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                             IOServiceMatching("AppleLMUController"));
    if (!serviceObject) {
        serviceObject = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                    IOServiceMatching("IOI2CDeviceLMU"));
    }
    
    return serviceObject;
}
@end
