#!/usr/bin/env swift
//
// Webcam Lamp Monitor
// Monitors webcam usage and upcoming calendar meetings to control HomeKit lamps
//
// Required Shortcuts (create these in Shortcuts.app):
//   - "MeetingON"   - turns desk lamp red, turns office lamp on
//   - "MeetingOFF"  - turns desk lamp green (office lamp unchanged)
//   - "MeetingSOON" - warning that meeting starts in 5 minutes
//

import Foundation
import CoreMediaIO
import EventKit

// Configuration
let shortcutOn = "MeetingON"
let shortcutOff = "MeetingOFF"
let shortcutSoon = "MeetingSOON"
let checkInterval: UInt32 = 2  // seconds
let meetingWarningMinutes = 5  // minutes before meeting to trigger warning
let debounceCount = 2  // Require this many consistent readings before changing state

// Lock file to prevent multiple instances
let lockFilePath = "/tmp/webcam-lamp-monitor.lock"
var lockFileDescriptor: Int32 = -1

// State tracking
var lastCameraState = false
var pendingState: Bool? = nil  // State we're transitioning to
var stableReadings = 0  // Count of consistent readings
var warnedMeetingIds = Set<String>()  // Track meetings we've already warned about
let eventStore = EKEventStore()
var calendarAccessGranted = false

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(formatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

func acquireLock() -> Bool {
    // Create or open lock file
    lockFileDescriptor = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
    if lockFileDescriptor < 0 {
        log("Error: Could not create lock file")
        return false
    }

    // Try to acquire exclusive lock (non-blocking)
    if flock(lockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
        log("Error: Another instance is already running")
        close(lockFileDescriptor)
        lockFileDescriptor = -1
        return false
    }

    // Write our PID to the lock file
    let pid = String(getpid())
    ftruncate(lockFileDescriptor, 0)
    lseek(lockFileDescriptor, 0, SEEK_SET)
    _ = pid.withCString { ptr in
        write(lockFileDescriptor, ptr, strlen(ptr))
    }

    return true
}

func releaseLock() {
    if lockFileDescriptor >= 0 {
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        unlink(lockFilePath)
        lockFileDescriptor = -1
    }
}

func requestCalendarAccess() {
    let semaphore = DispatchSemaphore(value: 0)

    if #available(macOS 14.0, *) {
        eventStore.requestFullAccessToEvents { granted, error in
            if let error = error {
                log("Calendar access error: \(error.localizedDescription)")
            }
            calendarAccessGranted = granted
            if granted {
                log("Calendar access granted")
            } else {
                log("Calendar access denied - meeting warnings will be disabled")
            }
            semaphore.signal()
        }
    } else {
        eventStore.requestAccess(to: .event) { granted, error in
            if let error = error {
                log("Calendar access error: \(error.localizedDescription)")
            }
            calendarAccessGranted = granted
            if granted {
                log("Calendar access granted")
            } else {
                log("Calendar access denied - meeting warnings will be disabled")
            }
            semaphore.signal()
        }
    }

    _ = semaphore.wait(timeout: .now() + 10)
}

func isAnyCameraActive() -> Bool {
    var propertyAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    var dataSize: UInt32 = 0
    var result = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize)

    guard result == 0 else { return false }

    let deviceCount = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
    var deviceIDs = Array(repeating: CMIODeviceID(0), count: deviceCount)
    result = CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataSize, &deviceIDs)

    guard result == 0 else { return false }

    for deviceID in deviceIDs {
        var isRunningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        let runningResult = CMIOObjectGetPropertyData(deviceID, &isRunningAddress, 0, nil, runningSize, &runningSize, &isRunning)

        if runningResult == 0 && isRunning != 0 {
            return true
        }
    }

    return false
}

// Video conferencing URL patterns
let videoLinkPatterns = [
    "zoom.us",
    "meet.google.com",
    "teams.microsoft.com",
    "webex.com",
    "gotomeeting.com",
    "whereby.com",
    "around.co",
    "gather.town",
    "discord.gg",
    "slack.com/call",
    "facetime:",
    "tel:"
]

func hasVideoLink(_ event: EKEvent) -> Bool {
    // Check URL field
    if let url = event.url?.absoluteString.lowercased() {
        for pattern in videoLinkPatterns {
            if url.contains(pattern) {
                return true
            }
        }
    }

    // Check notes/description for video links
    if let notes = event.notes?.lowercased() {
        for pattern in videoLinkPatterns {
            if notes.contains(pattern) {
                return true
            }
        }
    }

    // Check location field (often contains meeting links)
    if let location = event.location?.lowercased() {
        for pattern in videoLinkPatterns {
            if location.contains(pattern) {
                return true
            }
        }
    }

    return false
}

func hasAttendees(_ event: EKEvent) -> Bool {
    guard let attendees = event.attendees else { return false }
    // More than just yourself means it's a real meeting
    return attendees.count > 0
}

func isMeeting(_ event: EKEvent) -> Bool {
    // Event is a meeting if it has a video link OR has attendees
    return hasVideoLink(event) || hasAttendees(event)
}

func getUpcomingMeetings() -> [EKEvent] {
    guard calendarAccessGranted else { return [] }

    let now = Date()
    let warningWindow = TimeInterval(meetingWarningMinutes * 60)
    let lookAhead = TimeInterval(meetingWarningMinutes * 60 + 60)  // Check slightly ahead

    let startDate = now
    let endDate = now.addingTimeInterval(lookAhead)

    let calendars = eventStore.calendars(for: .event)
    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
    let events = eventStore.events(matching: predicate)

    // Filter to events starting within the warning window that are actual meetings
    return events.filter { event in
        let timeUntilStart = event.startDate.timeIntervalSince(now)
        // Event starts within warning window AND is a meeting (has video link or attendees)
        return timeUntilStart > 0 && timeUntilStart <= warningWindow && isMeeting(event)
    }
}

func checkUpcomingMeetings() {
    guard calendarAccessGranted else { return }

    // Don't warn about upcoming meetings if we're already in a meeting (camera active)
    if lastCameraState {
        return
    }

    let upcomingMeetings = getUpcomingMeetings()

    for meeting in upcomingMeetings {
        let meetingId = meeting.eventIdentifier ?? UUID().uuidString

        // Only warn once per meeting
        if !warnedMeetingIds.contains(meetingId) {
            let timeUntilStart = meeting.startDate.timeIntervalSince(Date())
            let minutesUntil = Int(timeUntilStart / 60)

            log("Upcoming meeting in \(minutesUntil) min: \(meeting.title ?? "Untitled")")
            runShortcut(shortcutSoon)
            warnedMeetingIds.insert(meetingId)
        }
    }

    // Clean up old meeting IDs (meetings that have already started)
    let now = Date()
    let calendars = eventStore.calendars(for: .event)
    let predicate = eventStore.predicateForEvents(
        withStart: now.addingTimeInterval(-3600),  // 1 hour ago
        end: now,
        calendars: calendars
    )
    let recentEvents = eventStore.events(matching: predicate)
    let recentIds = Set(recentEvents.compactMap { $0.eventIdentifier })

    // Remove IDs for meetings that started more than an hour ago
    warnedMeetingIds = warnedMeetingIds.intersection(recentIds.union(
        Set(upcomingMeetings.compactMap { $0.eventIdentifier })
    ))
}

func runShortcut(_ name: String) {
    log("Running shortcut: \(name)")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = ["run", name]

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            log("Shortcut completed successfully")
        } else {
            log("Warning: Shortcut may have failed (exit code \(process.terminationStatus))")
        }
    } catch {
        log("Error running shortcut: \(error.localizedDescription)")
    }
}

func main() {
    log("Webcam Lamp Monitor started")
    log("Shortcuts: ON='\(shortcutOn)', OFF='\(shortcutOff)', SOON='\(shortcutSoon)'")
    log("Check interval: \(checkInterval)s, Meeting warning: \(meetingWarningMinutes) min before")
    log("Debounce: \(debounceCount) consistent readings required")

    // Acquire lock to prevent multiple instances
    guard acquireLock() else {
        exit(1)
    }

    // Request calendar access
    requestCalendarAccess()

    // Handle graceful shutdown
    signal(SIGTERM) { _ in
        log("Shutting down...")
        releaseLock()
        exit(0)
    }
    signal(SIGINT) { _ in
        log("Shutting down...")
        releaseLock()
        exit(0)
    }

    var loopCount = 0

    while true {
        // Check camera state every loop
        let currentCameraState = isAnyCameraActive()

        // Debounce: require consistent readings before changing state
        if currentCameraState != lastCameraState {
            // State might be changing
            if pendingState == currentCameraState {
                // Same pending state, increment counter
                stableReadings += 1
            } else {
                // New pending state, reset counter
                pendingState = currentCameraState
                stableReadings = 1
            }

            // Only trigger state change after enough consistent readings
            if stableReadings >= debounceCount {
                if currentCameraState {
                    log("Camera became ACTIVE (after \(stableReadings) consistent readings)")
                    runShortcut(shortcutOn)
                } else {
                    log("Camera became INACTIVE (after \(stableReadings) consistent readings)")
                    runShortcut(shortcutOff)
                }
                lastCameraState = currentCameraState
                pendingState = nil
                stableReadings = 0
            }
        } else {
            // State is stable, reset pending
            pendingState = nil
            stableReadings = 0
        }

        // Check upcoming meetings every 30 seconds (15 loops at 2s interval)
        if loopCount % 15 == 0 {
            checkUpcomingMeetings()
        }

        loopCount += 1
        sleep(checkInterval)
    }
}

main()
