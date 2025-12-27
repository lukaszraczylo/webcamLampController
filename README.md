# Webcam Lamp Controller

Automatically controls your HomeKit lamps when your webcam is active or when meetings are approaching.

## How It Works

1. A compiled Swift binary monitors webcam usage every 2 seconds using CoreMediaIO
2. It also checks your calendar every 30 seconds for upcoming meetings
3. When a meeting is 5 minutes away, it runs "MeetingSOON"
4. When the webcam activates, it runs "MeetingON"
5. When the webcam deactivates, it runs "MeetingOFF"
6. You create these Shortcuts to control your HomeKit lamps however you want

## Setup

### Step 1: Create the Shortcuts

Open **Shortcuts.app** and create three shortcuts:

#### Shortcut: "MeetingSOON"
1. Click **+** to create new shortcut
2. Name it exactly: `MeetingSOON`
3. Add action: **Control [Your Desk Lamp]** → Set to **Yellow/Orange** (warning color)

#### Shortcut: "MeetingON"
1. Click **+** to create new shortcut
2. Name it exactly: `MeetingON`
3. Add action: **Control [Your Desk Lamp]** → Set to **Red**
4. Add action: **Control [Your Office Lamp]** → **Turn On**

#### Shortcut: "MeetingOFF"
1. Click **+** to create new shortcut
2. Name it exactly: `MeetingOFF`
3. Add action: **Control [Your Desk Lamp]** → Set to **Green**

(Office lamp is left unchanged)

> **Tip:** Search for "Home" in the actions to find HomeKit controls.

### Step 2: Test the Shortcuts

Run from Terminal to verify they work:
```bash
shortcuts run "MeetingON"
shortcuts run "MeetingOFF"
```

### Step 3: Build and Install

```bash
# Build and install (requires sudo for /usr/local/bin)
make install
```

This will:
- Compile the Swift source
- Install the binary to `/usr/local/bin`
- Set up the LaunchAgent for auto-start
- Start the service

### Step 4: Test

```bash
# Check status and recent logs
make status

# Follow logs in real-time
make logs
```

Open Photo Booth or start a video call to test camera detection.

### Managing the Service

```bash
make start    # Start the service
make stop     # Stop the service
make restart  # Restart the service
make status   # Show status and recent logs
make logs     # Follow the log file
```

### Uninstall

```bash
make uninstall
```

## Advanced Usage

### Command-Line Options

```bash
webcam-lamp-monitor [OPTIONS]

Options:
  --dry-run, -n     Run without executing shortcuts (testing mode)
  --debug, -d       Enable debug logging for troubleshooting
  --help, -h        Show help message
```

**Examples:**
```bash
# Test without actually running shortcuts
./webcam-lamp-monitor --dry-run

# Enable debug logging to see detailed camera and meeting detection
./webcam-lamp-monitor --debug

# Combine options
./webcam-lamp-monitor --dry-run --debug
```

### State Persistence

The daemon automatically saves its state to:
```
~/Library/Application Support/WebcamLampController/state.json
```

This prevents duplicate meeting warnings after daemon restarts and preserves the SOON state across system reboots.

### Log Levels

The daemon uses four log levels:
- **DEBUG**: Detailed information (camera checks, meeting detection logic, shortcut execution times)
- **INFO**: Normal operations (camera state changes, meeting warnings)
- **WARN**: Warnings (shortcut failures with retries, stale locks)
- **ERROR**: Critical errors (missing shortcuts, lock acquisition failures)

By default, INFO level and above are logged. Use `--debug` flag to see DEBUG logs.

## Customization

### Different Shortcut Names

Edit `webcam-lamp-monitor.swift`, change these lines, and recompile:
```swift
let shortcutOn = "MeetingON"
let shortcutOff = "MeetingOFF"
let shortcutSoon = "MeetingSOON"
```

### Check Interval

Edit `webcam-lamp-monitor.swift`, change this line, and recompile:
```swift
let checkInterval: UInt32 = 2  // seconds
```

### Meeting Warning Time

Edit `webcam-lamp-monitor.swift`, change this line, and recompile:
```swift
let meetingWarningMinutes = 5  // minutes before meeting to trigger warning
```

### Debouncing Configuration

Control how camera state changes are detected:
```swift
let debounceCount = 2  // Require N consistent readings before changing state
let debounceTimeoutSeconds = 10  // Force state change after this timeout
```

### Error Handling

Configure shortcut retry behavior:
```swift
let maxShortcutRetries = 2  // Number of retry attempts for failed shortcuts
let retryDelaySeconds = 3  // Delay between retry attempts
```

## Viewing Logs

```bash
# Real-time log
tail -f /tmp/webcam-lamp-monitor.log

# Or check recent activity
cat /tmp/webcam-lamp-monitor.log
```

## Troubleshooting

### Shortcuts not running
The daemon now validates shortcuts on startup and will exit with an error if any are missing.

**Solutions:**
- Make sure shortcut names match exactly (case-sensitive)
- Test shortcuts manually: `shortcuts run "MeetingON"`
- Ensure Shortcuts has HomeKit permissions
- Check startup logs for validation errors

### Camera not detected
- The monitor uses CoreMediaIO to detect active cameras
- Try opening Photo Booth to test camera detection
- Enable debug logging: Add `--debug` flag to see which cameras are detected
- Check logs: `tail -f /tmp/webcam-lamp-monitor.log`

### LaunchAgent not starting
- Check for errors: `launchctl list | grep webcam`
- View logs: `cat /tmp/webcam-lamp-monitor.log`
- Make sure the script path in the plist is correct

### Debugging Meeting Detection

If meetings aren't triggering the SOON warning:

1. **Enable debug logging**:
   ```bash
   # Stop the service
   make stop

   # Run manually with debug logging
   ~/.local/bin/webcam-lamp-monitor --debug
   ```

2. **Check what the daemon sees**:
   - Debug logs show all calendar events examined
   - Shows whether each event has video links or attendees
   - Displays time until each meeting starts

3. **Common issues**:
   - All-day events are automatically filtered out
   - Events need either a video conference link OR attendees to be considered meetings
   - Video link patterns: zoom.us, meet.google.com, teams.microsoft.com, etc.
   - Check that calendar access is granted in System Settings → Privacy & Security → Calendars

### Duplicate Meeting Warnings

If you receive duplicate SOON warnings for the same meeting:
- This should no longer happen - the daemon now persists warned meetings to disk
- Check state file: `cat ~/Library/Application\ Support/WebcamLampController/state.json`
- If issues persist, delete the state file and restart the daemon

### Shortcut Execution Failures

The daemon now automatically retries failed shortcuts up to 2 times with a 3-second delay:
- Check logs for retry attempts
- Persistent failures after 3 attempts indicate a problem with the shortcut itself
- Test the shortcut manually to ensure it works correctly

## How Meeting Detection Works

The daemon intelligently filters calendar events to identify real meetings:

### Criteria for Meetings
An event is considered a meeting if it has:
1. **Video conference link** (Zoom, Google Meet, Teams, Webex, etc.) OR
2. **Attendees** (more than just you)

### Automatic Filtering
- **All-day events** are never considered meetings (birthdays, holidays, etc.)
- Events are checked 5 minutes before they start
- Only future events within the warning window are considered

### Supported Video Conference Patterns
- zoom.us
- meet.google.com
- teams.microsoft.com
- webex.com
- gotomeeting.com
- whereby.com
- around.co
- gather.town
- discord.gg
- slack.com/call
- facetime:
- tel:

Links can appear in the event's URL field, notes/description, or location field.

## Architecture & Design Decisions

### Debouncing Strategy
Camera state changes require 2 consecutive consistent readings (4 seconds) before triggering shortcuts. This prevents false positives from brief camera activations.

Additionally, if the camera state oscillates rapidly, a 10-second timeout forces the state change to prevent indefinite waiting.

### Shortcut Queue Management
Only one shortcut runs at a time. The queue intelligently coalesces rapid changes:
- **ON/OFF shortcuts**: Replace any pending shortcut (handles rapid camera toggles)
- **SOON shortcuts**: Only queue if nothing else is pending (won't interrupt ON/OFF)

This prevents shortcut "chattering" and ensures the final desired state is reached efficiently.

### SOON State Expiration
If you receive a meeting warning (SOON) but don't activate your camera within 5 minutes after the meeting starts, the daemon automatically returns lamps to OFF state.

This prevents lamps from staying in "warning" mode indefinitely for meetings you don't join.

### Lock File Management
The daemon prevents multiple instances from running simultaneously using a lock file at:
```
~/Library/Application Support/WebcamLampController/webcam-lamp-monitor.lock
```

Stale locks from crashed processes are automatically detected and cleaned up.

## Performance Characteristics

- **CPU Usage**: ~0.1% on modern Macs (polling overhead is minimal)
- **Memory**: ~10-15 MB (Swift runtime + event store)
- **Camera Check**: ~1-2ms every 2 seconds
- **Calendar Check**: ~10-50ms every 30 seconds (only when calendar access granted)
- **Shortcut Execution**: Depends on shortcut complexity (typically 1-3 seconds)

## Files

- `webcam-lamp-monitor.swift` - Swift source code
- `com.webcamlampcontroller.plist` - LaunchAgent template
- `Makefile` - Build and install automation
- `~/Library/Application Support/WebcamLampController/state.json` - Persisted state
- `~/Library/Application Support/WebcamLampController/webcam-lamp-monitor.lock` - Instance lock
- `/tmp/webcam-lamp-monitor.log` - Runtime logs

## Recent Improvements

- ✅ **State Persistence**: Prevents duplicate meeting warnings after daemon restarts
- ✅ **Shortcut Validation**: Validates shortcuts exist on startup with clear error messages
- ✅ **Retry Logic**: Automatically retries failed shortcuts (up to 2 retries)
- ✅ **Logging Levels**: DEBUG/INFO/WARN/ERROR levels for better troubleshooting
- ✅ **Debug Mode**: `--debug` flag for detailed logging during troubleshooting
- ✅ **Dry-Run Mode**: `--dry-run` flag for testing without executing shortcuts
- ✅ **Improved Debouncing**: Timeout prevents indefinite waiting during rapid camera toggles
- ✅ **Better Error Messages**: More descriptive logging with execution times
- ✅ **Single Worker Thread**: Fixed potential race condition in shortcut queue
- ✅ **All Meetings Checked**: SOON expiration now checks all meetings, not just first

## Compatibility

- **macOS**: 12.0+ (Monterey and later)
- **Swift**: 5.5+
- **Shortcuts.app**: Built-in on macOS 12+
- **EventKit**: Calendar access requires user permission
