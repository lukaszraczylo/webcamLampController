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

## Viewing Logs

```bash
# Real-time log
tail -f /tmp/webcam-lamp-monitor.log

# Or check recent activity
cat /tmp/webcam-lamp-monitor.log
```

## Troubleshooting

### Shortcuts not running
- Make sure shortcut names match exactly (case-sensitive)
- Test shortcuts manually: `shortcuts run "MeetingON"`
- Ensure Shortcuts has HomeKit permissions

### Camera not detected
- The monitor uses CoreMediaIO to detect active cameras
- Try opening Photo Booth to test camera detection
- Check logs: `tail -f /tmp/webcam-lamp-monitor.log`

### LaunchAgent not starting
- Check for errors: `launchctl list | grep webcam`
- View logs: `cat /tmp/webcam-lamp-monitor.log`
- Make sure the script path in the plist is correct

## Files

- `webcam-lamp-monitor.swift` - Swift source code
- `com.webcamlampcontroller.plist` - LaunchAgent template
- `Makefile` - Build and install automation
