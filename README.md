# University-ParkPlace
Please read the disclaimer and licensing information before use.
License: Non-Commercial (UPP-NC-1.0). 
Commercial use requires a separate license – contact: <mixinzh@outlook.com>.

This is a Swift-based iOS app that sends arrival alerts using geofencing, so students do not forget to pay for parking. It runs entirely on the device. No servers. No analytics. Location is only used to trigger local notifications.  
Compared to Shortcuts on iPhone and other reminder apps, this one does not trigger false-positive alerts and will update the monitored region itself so that you don't have to manually adjust the lot being monitored.
It ships with UC Davis as the example campus. You can adjust it to make it suitable for any other campus by changing a few constants. 

## Goal & Flow
The goal of this app is to remind users to pay when users arrive in a campus lot, then it will fire a follow-up reminder if users ignore the first one. This app uses a two-layer geofence system where it sets a large campus “sentinel” region to wake the app when users get near campus, and it will monitor up to 19 small lot regions that will actually trigger the pay flow.

This app will fire the first alert when users enter a lot. The first alert allows the user to choose from getting a follow-up notification in 30 minutes or Paid (no later notification). After the second notification has been fired, if users ignore it, a final reminder will be sent 30 minutes later. There is only one chain per day, assuming that all users use a day pass that allows parking in all lots.

Everything is local. If users tap the alert, the app hands users off to the AIMS Mobile Pay website; if users' campus uses another provider, change accordingly.

## Files and main pieces
- AppCoordinator: wires up the shared GeoManager instance.  
**UI:**  
- ContentView: title, permission hints, a “Refresh lots now” button, status text, and the payment control panel.  
- PayControlsView: “Open AIMS Mobile Pay,” “I paid,” “Remind me later.”  
- LoadingButton, StatusBar, StatusPill, and a small pressable button style.  
**Location and geofencing:**  
- GeoManager: the singleton that owns CLLocationManager, discovers lot coordinates, starts/stops geofences, and manages permissions, precision mode, and UI state.  
**Notifications and flow control:**  
- GeofenceEventRouter: decides when an alert chain can start, schedules follow-ups, enforces a daily cap and a small global throttle.  
- NotificationHandler: registers categories, posts notifications, responds to button taps and banner taps.

## Constants you will change for another campus
- campusCenter: latitude and longitude of your campus center.  
- campusLatRange and campusLonRange: bounding box that keeps search results on campus.  
- campusSearchSpan: MKLocalSearch span; smaller span means fewer off-campus results.  
- desiredGeofenceRadius: meters for each lot geofence (defaults to 150 m).  
- reshuffleThresholdMeters: how far the device must move before we re-pick the nearest lots (400 m by default).  
- excludedCoordinates: list of coordinates to exclude (for example, nearby grocery store or mall lots that are free).

## How the app discovers and monitors lots
When services start or the user moves a distance, `GeoManager.refreshLotsAndRegions()` runs an MKLocalSearch for "parking" centered on `campusCenter` and constrained by `campusSearchSpan`.

The results of the search are limited to `campusLatRange` and `campusLonRange`. Anything on the exclusion list is removed. From the filtered list, it picks the nearest 19 to users' current anchor, and it starts region monitoring for those 19 and always keeps one extra region armed.

For the campus sentinel, iOS will activate the app for region events. The large sentinel region around campus is always armed. It wakes the app when users approach campus, so we can refresh lot regions right on time. Also, it lets the app pause lot monitoring when users are far away (to save system work), while still staying ready.  
When users enter the sentinel, the app refreshes lots and briefly turns on precision mode.  
- Most of the time, we let Core Location run in a light mode. When users are near campus or near a monitored lot, the app will enable background updates, raise accuracy, set an automotive activity type, and run for ~90–120 seconds.  
If during that window users' location fix shows users are already inside a lot region, the app fires the “you are in a UC Davis parking lot” alert, flips the pay flow to active, and ends precision mode early.

## The alert chain
We use GeofenceEventRouter as a gatekeeper, so it stores minimal state in UserDefaults.  
After T0 is fired, we provide two options, Paid (ends the chain for today) and Remind me later (schedules a 30-minute reminder). After 30 minutes, the “Mark as paid or get one more reminder” notification will be fired. If the user snoozes here, it schedules the final 60-minute reminder. Any “Paid” action or tapping the banner to open AIMS Mobile Pay ends the flow and cancels pending follow-ups.  
In the app, `payFlowActive` flips the payment controls panel from “Locked” to “Ready.” Users can also mark “I paid” in the app, which ends the chain.  
There is one chain per day. If users leave and re-enter multiple lots, it will not spam users.

The app opens the AIMS Mobile Pay website in the browser as I couldn’t find the universal link for opening the AMP app; replace this if users' campus uses another provider.

## Permissions, background, and first run
On first launch, the app asks for When In Use location. After users start using it, it requests Always so alerts can fire in the background. It also asks for Notifications. If users decline, the UI shows a button to jump to Settings.  
If the system launches the app because of a location event, AppDelegate wires the CLLocationManager to the shared GeoManager, re-arms the sentinel, and queries its state.

## Required setup to build and run
Choose something modern (iOS 15 or later is typical). The code uses SwiftUI and modern Core Location.  
**Info.plist:**  
- `NSLocationWhenInUseUsageDescription`  
- `NSLocationAlwaysAndWhenInUseUsageDescription`

## Exclusions and false positives
One exclusion is baked in the example to avoid a Trader Joe’s lot that is not part of UC Davis parking:  
latitude: 38.547401850985445  
longitude: -121.76088731557454  
You can add more if your campus is surrounded by free retail lots. This is just an example.
