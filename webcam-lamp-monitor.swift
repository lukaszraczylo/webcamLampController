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
var dryRun = false  // Set to true to skip actual shortcut execution
let shortcutOn = "MeetingON"
let shortcutOff = "MeetingOFF"
let shortcutSoon = "MeetingSOON"
let checkInterval: UInt32 = 2  // seconds
let meetingWarningMinutes = 5  // minutes before meeting to trigger warning
let debounceCount = 2  // Require this many consistent readings before changing state
let debounceTimeoutSeconds = 10  // Force state change after this many seconds in pending state

// Error handling configuration
let maxShortcutRetries = 2  // Number of retry attempts for failed shortcuts
let retryDelaySeconds = 3  // Delay between retry attempts

// Calendar configuration
let calendarLookAheadBufferSeconds = 60  // Extra time to check beyond warning window
let meetingCleanupWindowSeconds = 3600   // How far back to check for old meetings (1 hour)
let meetingCheckIntervalCycles = 15      // Check meetings every N cycles (30s at 2s interval)

// Lock file to prevent multiple instances
let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let lockDirPath = appSupportDir.appendingPathComponent("WebcamLampController").path
let lockFilePath = appSupportDir.appendingPathComponent("WebcamLampController/webcam-lamp-monitor.lock").path
let stateFilePath = appSupportDir.appendingPathComponent("WebcamLampController/state.json").path
var lockFileDescriptor: Int32 = -1

// State tracking
var lastCameraState = false
var pendingState: Bool? = nil  // State we're transitioning to
var stableReadings = 0  // Count of consistent readings
var pendingStateStartTime: Date? = nil  // When we entered pending state
var warnedMeetingIds = Set<String>()  // Track meetings we've already warned about
var meetingStartTimes = [String: Date]()  // Track start times of meetings we warned about
var inSoonState = false  // Track if we're currently in SOON state (lamp showing warning)
let eventStore = EKEventStore()
var calendarAccessGranted = false

// Shortcut queue - only keeps the final desired state
let shortcutLock = NSLock()
var pendingShortcut: String? = nil
let shortcutSemaphore = DispatchSemaphore(value: 0)
let shortcutQueue = DispatchQueue(label: "com.webcamlampcontroller.shortcuts")

// Logging
enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

var currentLogLevel: LogLevel = .info  // Can be changed to .debug for troubleshooting

func log(_ message: String, level: LogLevel = .info) {
    // Filter based on log level
    let levelPriority: [LogLevel: Int] = [.debug: 0, .info: 1, .warn: 2, .error: 3]
    guard levelPriority[level]! >= levelPriority[currentLogLevel]! else { return }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(formatter.string(from: Date()))] [\(level.rawValue)] \(message)")
    fflush(stdout)
}

func isProcessRunning(pid: pid_t) -> Bool {
    // kill with signal 0 checks if process exists without sending a signal
    return kill(pid, 0) == 0
}

// State persistence
struct PersistedState: Codable {
    var warnedMeetingIds: [String]
    var meetingStartTimes: [String: TimeInterval]  // Store as TimeInterval since epoch
    var inSoonState: Bool
}

func saveState() {
    let state = PersistedState(
        warnedMeetingIds: Array(warnedMeetingIds),
        meetingStartTimes: meetingStartTimes.mapValues { $0.timeIntervalSince1970 },
        inSoonState: inSoonState
    )

    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(state)
        try data.write(to: URL(fileURLWithPath: stateFilePath))
        log("State saved", level: .debug)
    } catch {
        log("Failed to save state: \(error.localizedDescription)", level: .warn)
    }
}

func loadState() {
    guard FileManager.default.fileExists(atPath: stateFilePath) else {
        log("No previous state file found", level: .debug)
        return
    }

    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: stateFilePath))
        let decoder = JSONDecoder()
        let state = try decoder.decode(PersistedState.self, from: data)

        warnedMeetingIds = Set(state.warnedMeetingIds)
        meetingStartTimes = state.meetingStartTimes.mapValues { Date(timeIntervalSince1970: $0) }
        inSoonState = state.inSoonState

        log("State loaded: \(warnedMeetingIds.count) warned meetings, inSoonState=\(inSoonState)", level: .debug)
    } catch {
        log("Failed to load state: \(error.localizedDescription)", level: .warn)
    }
}

func cleanStaleLock() -> Bool {
    // Try to read the PID from existing lock file
    guard let contents = try? String(contentsOfFile: lockFilePath, encoding: .utf8),
          let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        // Can't read PID, assume stale and remove
        log("Removing unreadable lock file", level: .warn)
        unlink(lockFilePath)
        return true
    }

    // Check if the process is still running
    if isProcessRunning(pid: pid) {
        return false  // Process is alive, lock is valid
    }

    // Process is dead, remove stale lock
    log("Removing stale lock file (PID \(pid) is not running)", level: .warn)
    unlink(lockFilePath)
    return true
}

func acquireLock() -> Bool {
    // Ensure lock directory exists
    try? FileManager.default.createDirectory(atPath: lockDirPath, withIntermediateDirectories: true, attributes: nil)

    // Create or open lock file
    lockFileDescriptor = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
    if lockFileDescriptor < 0 {
        log("Could not create lock file", level: .error)
        return false
    }

    // Try to acquire exclusive lock (non-blocking)
    if flock(lockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
        close(lockFileDescriptor)
        lockFileDescriptor = -1

        // Check if the lock is stale
        if cleanStaleLock() {
            // Try again after cleaning stale lock
            lockFileDescriptor = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
            if lockFileDescriptor < 0 {
                log("Could not create lock file after cleanup", level: .error)
                return false
            }
            if flock(lockFileDescriptor, LOCK_EX | LOCK_NB) != 0 {
                log("Could not acquire lock after cleanup", level: .error)
                close(lockFileDescriptor)
                lockFileDescriptor = -1
                return false
            }
        } else {
            log("Another instance is already running", level: .error)
            return false
        }
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
                log("Calendar access error: \(error.localizedDescription)", level: .error)
            }
            calendarAccessGranted = granted
            if granted {
                log("Calendar access granted")
            } else {
                log("Calendar access denied - meeting warnings will be disabled", level: .warn)
            }
            semaphore.signal()
        }
    } else {
        eventStore.requestAccess(to: .event) { granted, error in
            if let error = error {
                log("Calendar access error: \(error.localizedDescription)", level: .error)
            }
            calendarAccessGranted = granted
            if granted {
                log("Calendar access granted")
            } else {
                log("Calendar access denied - meeting warnings will be disabled", level: .warn)
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

    guard result == 0 else {
        log("Failed to get camera device list size (result: \(result))", level: .warn)
        return false
    }

    let deviceCount = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
    log("Found \(deviceCount) camera device(s)", level: .debug)

    var deviceIDs = Array(repeating: CMIODeviceID(0), count: deviceCount)
    result = CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataSize, &deviceIDs)

    guard result == 0 else {
        log("Failed to get camera device list (result: \(result))", level: .warn)
        return false
    }

    for (index, deviceID) in deviceIDs.enumerated() {
        var isRunningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        let runningResult = CMIOObjectGetPropertyData(deviceID, &isRunningAddress, 0, nil, runningSize, &runningSize, &isRunning)

        if runningResult == 0 && isRunning != 0 {
            log("Camera device #\(index) (ID: \(deviceID)) is ACTIVE", level: .debug)
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
    // All-day events are never meetings (birthdays, holidays, reminders, etc.)
    if event.isAllDay {
        log("Event '\(event.title ?? "Untitled")' is all-day, skipping", level: .debug)
        return false
    }

    let hasVideo = hasVideoLink(event)
    let hasAtts = hasAttendees(event)

    log("Event '\(event.title ?? "Untitled")': videoLink=\(hasVideo), attendees=\(hasAtts)", level: .debug)

    // Event is a meeting if it has a video link OR has attendees
    return hasVideo || hasAtts
}

func getUpcomingMeetings() -> [EKEvent] {
    guard calendarAccessGranted else { return [] }

    let now = Date()
    let warningWindow = TimeInterval(meetingWarningMinutes * 60)
    let lookAhead = TimeInterval(meetingWarningMinutes * 60 + calendarLookAheadBufferSeconds)

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
    guard calendarAccessGranted else {
        log("Skipping meeting check: calendar access not granted", level: .debug)
        return
    }

    // Don't warn about upcoming meetings if we're already in a meeting (camera active)
    if lastCameraState {
        log("Skipping meeting check: camera already active", level: .debug)
        return
    }

    let upcomingMeetings = getUpcomingMeetings()
    log("Found \(upcomingMeetings.count) upcoming meeting(s)", level: .debug)

    for meeting in upcomingMeetings {
        let meetingId = meeting.eventIdentifier ?? UUID().uuidString

        // Only warn once per meeting
        if !warnedMeetingIds.contains(meetingId) {
            let timeUntilStart = meeting.startDate.timeIntervalSince(Date())
            let minutesUntil = Int(timeUntilStart / 60)

            log("Upcoming meeting in \(minutesUntil) min: \(meeting.title ?? "Untitled")")
            runShortcut(shortcutSoon)
            warnedMeetingIds.insert(meetingId)
            meetingStartTimes[meetingId] = meeting.startDate
            inSoonState = true
            saveState()  // Persist state after warning
        }
    }

    // Clean up old meeting IDs (meetings that have already started)
    let now = Date()
    let calendars = eventStore.calendars(for: .event)
    let predicate = eventStore.predicateForEvents(
        withStart: now.addingTimeInterval(-TimeInterval(meetingCleanupWindowSeconds)),
        end: now,
        calendars: calendars
    )
    let recentEvents = eventStore.events(matching: predicate)
    let recentIds = Set(recentEvents.compactMap { $0.eventIdentifier })

    // Remove IDs for meetings that started more than an hour ago
    let validIds = recentIds.union(Set(upcomingMeetings.compactMap { $0.eventIdentifier }))
    let previousCount = warnedMeetingIds.count
    warnedMeetingIds = warnedMeetingIds.intersection(validIds)

    // Also clean up meetingStartTimes
    meetingStartTimes = meetingStartTimes.filter { validIds.contains($0.key) }

    // Save state if we cleaned up any IDs
    if warnedMeetingIds.count != previousCount {
        saveState()
    }
}

/// Check if SOON state should expire (5 minutes into a meeting with no camera activation)
func checkSoonExpiration() {
    guard inSoonState else { return }
    guard !lastCameraState else { return }  // Camera is active, don't expire

    let now = Date()
    let expirationThreshold = TimeInterval(meetingWarningMinutes * 60)  // 5 minutes into meeting

    // Find all meetings that have expired (started 5+ minutes ago)
    var expiredMeetingIds: [String] = []

    for (meetingId, startTime) in meetingStartTimes {
        let timeSinceStart = now.timeIntervalSince(startTime)

        if timeSinceStart >= expirationThreshold {
            log("Meeting expired: started \(Int(timeSinceStart / 60)) min ago without camera activation (ID: \(meetingId))", level: .debug)
            expiredMeetingIds.append(meetingId)
        }
    }

    // If we have expired meetings, handle the expiration
    if !expiredMeetingIds.isEmpty {
        log("SOON state expired: \(expiredMeetingIds.count) meeting(s) started without camera activation")
        runShortcut(shortcutOff)
        inSoonState = false

        // Remove all expired meetings from tracking
        for meetingId in expiredMeetingIds {
            meetingStartTimes.removeValue(forKey: meetingId)
        }
        saveState()  // Persist state change
    }
}

func listAvailableShortcuts() -> [String] {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = ["list"]
    process.standardOutput = pipe

    do {
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            return output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    } catch {
        log("Failed to list shortcuts: \(error.localizedDescription)", level: .warn)
    }

    return []
}

func validateShortcuts() -> Bool {
    log("Validating shortcuts...")

    let availableShortcuts = listAvailableShortcuts()
    let requiredShortcuts = [shortcutOn, shortcutOff, shortcutSoon]
    var allValid = true

    for shortcut in requiredShortcuts {
        if availableShortcuts.contains(shortcut) {
            log("✓ Shortcut '\(shortcut)' found", level: .debug)
        } else {
            log("✗ Shortcut '\(shortcut)' NOT FOUND", level: .error)
            allValid = false
        }
    }

    if !allValid {
        log("", level: .error)
        log("ERROR: Some required shortcuts are missing!", level: .error)
        log("Please create the missing shortcuts in Shortcuts.app:", level: .error)
        for shortcut in requiredShortcuts {
            if !availableShortcuts.contains(shortcut) {
                log("  - \(shortcut)", level: .error)
            }
        }
        log("See README.md for setup instructions.", level: .error)
    } else {
        log("All required shortcuts are available ✓")
    }

    return allValid
}

func executeShortcut(_ name: String) {
    if dryRun {
        log("[DRY-RUN] Would execute shortcut '\(name)'")
        return
    }

    var attempts = 0
    let maxAttempts = maxShortcutRetries + 1  // Initial attempt + retries

    while attempts < maxAttempts {
        attempts += 1
        let attemptLabel = attempts > 1 ? " (attempt \(attempts)/\(maxAttempts))" : ""

        let startTime = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]

        do {
            try process.run()
            process.waitUntilExit()

            let duration = Date().timeIntervalSince(startTime)

            if process.terminationStatus == 0 {
                log("Shortcut '\(name)' completed successfully in \(String(format: "%.2f", duration))s\(attemptLabel)", level: .debug)
                return  // Success - exit retry loop
            } else {
                let message = "Shortcut '\(name)' failed with exit code \(process.terminationStatus) after \(String(format: "%.2f", duration))s\(attemptLabel)"

                if attempts < maxAttempts {
                    log("\(message), retrying in \(retryDelaySeconds)s...", level: .warn)
                    sleep(UInt32(retryDelaySeconds))
                } else {
                    log("\(message), giving up after \(attempts) attempts", level: .error)
                }
            }
        } catch {
            let message = "Error running shortcut '\(name)': \(error.localizedDescription)\(attemptLabel)"

            if attempts < maxAttempts {
                log("\(message), retrying in \(retryDelaySeconds)s...", level: .warn)
                sleep(UInt32(retryDelaySeconds))
            } else {
                log("\(message), giving up after \(attempts) attempts", level: .error)
            }
        }
    }
}

func startShortcutWorker() {
    shortcutQueue.async {
        while true {
            // Wait for a shortcut to be queued
            shortcutSemaphore.wait()

            // Get the shortcut to run
            shortcutLock.lock()
            let shortcutToRun = pendingShortcut
            pendingShortcut = nil
            shortcutLock.unlock()

            // Run it if we have one
            if let name = shortcutToRun {
                log("Running shortcut: \(name)")
                executeShortcut(name)
            }
        }
    }
}

func runShortcut(_ name: String) {
    shortcutLock.lock()

    let hadPendingShortcut = (pendingShortcut != nil)

    // For ON/OFF shortcuts, replace any pending shortcut (coalesce rapid changes)
    if name == shortcutOn || name == shortcutOff {
        if let pending = pendingShortcut, pending != name {
            log("Replacing pending shortcut '\(pending)' with '\(name)'", level: .debug)
        }
        pendingShortcut = name
    } else {
        // For other shortcuts (like SOON), queue if nothing pending
        if pendingShortcut == nil {
            pendingShortcut = name
        } else {
            // SOON doesn't replace ON/OFF, just skip if something is pending
            log("Skipping '\(name)' - another shortcut is pending", level: .debug)
            shortcutLock.unlock()
            return
        }
    }

    shortcutLock.unlock()

    // Signal the worker thread only if we just added a new shortcut
    // (not if we replaced an existing pending one)
    if !hadPendingShortcut {
        shortcutSemaphore.signal()
    }
}

func main() {
    // Parse command-line arguments
    let args = CommandLine.arguments
    if args.contains("--dry-run") || args.contains("-n") {
        dryRun = true
    }
    if args.contains("--debug") || args.contains("-d") {
        currentLogLevel = .debug
    }
    if args.contains("--help") || args.contains("-h") {
        print("Usage: webcam-lamp-monitor [OPTIONS]")
        print("")
        print("Options:")
        print("  --dry-run, -n     Run without executing shortcuts (testing mode)")
        print("  --debug, -d       Enable debug logging")
        print("  --help, -h        Show this help message")
        exit(0)
    }

    log("Webcam Lamp Monitor started\(dryRun ? " [DRY-RUN MODE]" : "")")
    log("Shortcuts: ON='\(shortcutOn)', OFF='\(shortcutOff)', SOON='\(shortcutSoon)'")
    log("Check interval: \(checkInterval)s, Meeting warning: \(meetingWarningMinutes) min before")
    log("Debounce: \(debounceCount) consistent readings required")
    log("Log level: \(currentLogLevel.rawValue)")

    // Acquire lock to prevent multiple instances
    guard acquireLock() else {
        exit(1)
    }

    // Load persisted state
    loadState()

    // Validate required shortcuts exist
    guard validateShortcuts() else {
        log("Exiting due to missing shortcuts", level: .error)
        releaseLock()
        exit(1)
    }

    // Start the shortcut worker thread
    startShortcutWorker()

    // Request calendar access
    requestCalendarAccess()

    // Handle graceful shutdown
    signal(SIGTERM) { _ in
        log("Shutting down...")
        saveState()
        releaseLock()
        exit(0)
    }
    signal(SIGINT) { _ in
        log("Shutting down...")
        saveState()
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
                // New pending state, reset counter and start time
                pendingState = currentCameraState
                stableReadings = 1
                pendingStateStartTime = Date()
            }

            // Check if we should trigger state change
            var shouldTrigger = false
            var triggerReason = ""

            if stableReadings >= debounceCount {
                shouldTrigger = true
                triggerReason = "after \(stableReadings) consistent readings"
            } else if let startTime = pendingStateStartTime {
                // Force trigger if we've been in pending state too long
                let timeInPending = Date().timeIntervalSince(startTime)
                if timeInPending >= TimeInterval(debounceTimeoutSeconds) {
                    shouldTrigger = true
                    triggerReason = "timeout after \(Int(timeInPending))s in pending state"
                }
            }

            if shouldTrigger {
                if currentCameraState {
                    log("Camera became ACTIVE (\(triggerReason))")
                    runShortcut(shortcutOn)
                    if inSoonState {
                        inSoonState = false  // Camera activated, no longer in SOON state
                        saveState()  // Persist state change
                    }
                } else {
                    log("Camera became INACTIVE (\(triggerReason))")
                    runShortcut(shortcutOff)
                }
                lastCameraState = currentCameraState
                pendingState = nil
                stableReadings = 0
                pendingStateStartTime = nil
            }
        } else {
            // State is stable, reset pending
            pendingState = nil
            stableReadings = 0
            pendingStateStartTime = nil
        }

        // Check upcoming meetings and SOON expiration periodically
        if loopCount % meetingCheckIntervalCycles == 0 {
            checkUpcomingMeetings()
            checkSoonExpiration()
        }

        loopCount += 1
        sleep(checkInterval)
    }
}

main()
