// The phone's battery for the HUD (scripts/status_hud.gd). Godot has no
// battery API and GDScript cannot reach UIKit, so this keeps UIDevice's battery
// in the process environment, where the game reads it with OS.get_environment:
//   POKEWILDS_BATTERY="<percent 0-100, or -1 when unknown>,<UIDeviceBatteryState>"
// with the state 0 unknown, 1 unplugged, 2 charging, 3 full.
// iOS posts these notifications on the main queue and Godot's game loop runs
// on the main thread too, so the value never changes under a read.
// CI builds libpokewilds_battery.a from this file (the ios job, tools/ios_xtool);
// Godot's export links it and calls the two functions named in the .gdip.
#import <UIKit/UIKit.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static NSArray *observers;

static void publish() {
	UIDevice *device = UIDevice.currentDevice;
	float level = device.batteryLevel;
	char value[16];
	snprintf(value, sizeof(value), "%d,%d", level < 0.0f ? -1 : (int)lroundf(level * 100.0f), (int)device.batteryState);
	setenv("POKEWILDS_BATTERY", value, 1);
}

void pokewilds_battery_init() {
	UIDevice.currentDevice.batteryMonitoringEnabled = YES;
	NSMutableArray *list = [NSMutableArray array];
	// iOS sends a level change at most once a minute; coming back to the game
	// reads both again, as nothing is sent while it sleeps in the background.
	for (NSNotificationName name in @[ UIDeviceBatteryLevelDidChangeNotification, UIDeviceBatteryStateDidChangeNotification, UIApplicationDidBecomeActiveNotification ]) {
		[list addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
			publish();
		}]];
	}
	observers = list;
	publish();
}

void pokewilds_battery_deinit() {
	for (id observer in observers) {
		[NSNotificationCenter.defaultCenter removeObserver:observer];
	}
	observers = nil;
	UIDevice.currentDevice.batteryMonitoringEnabled = NO;
}
