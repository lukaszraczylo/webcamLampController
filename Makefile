# Webcam Lamp Controller Makefile

BINARY_NAME = webcam-lamp-monitor
SOURCE_FILE = webcam-lamp-monitor.swift
INSTALL_DIR = $(HOME)/.local/bin
PLIST_NAME = com.webcamlampcontroller.plist
LAUNCHAGENTS_DIR = $(HOME)/Library/LaunchAgents

.PHONY: all build install uninstall start stop restart status clean

all: build

build: $(BINARY_NAME)

$(BINARY_NAME): $(SOURCE_FILE)
	@echo "Compiling $(SOURCE_FILE)..."
	swiftc -O -o $(BINARY_NAME) $(SOURCE_FILE)
	@echo "Build complete: $(BINARY_NAME)"

install: build
	@echo "Stopping service if running..."
	-launchctl unload $(LAUNCHAGENTS_DIR)/$(PLIST_NAME) 2>/dev/null
	@echo "Installing binary to $(INSTALL_DIR)..."
	@mkdir -p $(INSTALL_DIR)
	cp $(BINARY_NAME) $(INSTALL_DIR)/
	chmod 755 $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "Installing LaunchAgent..."
	@sed 's|__INSTALL_DIR__|$(INSTALL_DIR)|g' $(PLIST_NAME) > $(LAUNCHAGENTS_DIR)/$(PLIST_NAME)
	@echo "Starting service..."
	launchctl load $(LAUNCHAGENTS_DIR)/$(PLIST_NAME)
	@echo "Installation complete!"
	@echo "View logs: tail -f /tmp/webcam-lamp-monitor.log"

uninstall:
	@echo "Stopping service..."
	-launchctl unload $(LAUNCHAGENTS_DIR)/$(PLIST_NAME) 2>/dev/null
	@echo "Removing LaunchAgent..."
	-rm -f $(LAUNCHAGENTS_DIR)/$(PLIST_NAME)
	@echo "Removing binary..."
	-rm -f $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "Uninstall complete!"

start:
	@if [ -f $(LAUNCHAGENTS_DIR)/$(PLIST_NAME) ]; then \
		launchctl load $(LAUNCHAGENTS_DIR)/$(PLIST_NAME); \
		echo "Service started"; \
	else \
		echo "Service not installed. Run 'make install' first."; \
	fi

stop:
	@if [ -f $(LAUNCHAGENTS_DIR)/$(PLIST_NAME) ]; then \
		launchctl unload $(LAUNCHAGENTS_DIR)/$(PLIST_NAME); \
		echo "Service stopped"; \
	else \
		echo "Service not installed."; \
	fi

restart: stop start

status:
	@echo "=== Service Status ==="
	@if launchctl list 2>/dev/null | grep -q webcamlampcontroller; then \
		echo "Status: Running"; \
		launchctl list | grep webcamlampcontroller; \
	else \
		echo "Status: Not running"; \
	fi
	@echo ""
	@echo "=== Recent Logs ==="
	@if [ -f /tmp/webcam-lamp-monitor.log ]; then \
		tail -5 /tmp/webcam-lamp-monitor.log; \
	else \
		echo "No log file found"; \
	fi

logs:
	@tail -f /tmp/webcam-lamp-monitor.log

clean:
	@echo "Cleaning build artifacts..."
	-rm -f $(BINARY_NAME)
	@echo "Clean complete"

help:
	@echo "Webcam Lamp Controller - Available targets:"
	@echo ""
	@echo "  make build     - Compile the Swift source"
	@echo "  make install   - Build, install to $(INSTALL_DIR), and start service"
	@echo "  make uninstall - Stop service and remove all installed files"
	@echo "  make start     - Start the service"
	@echo "  make stop      - Stop the service"
	@echo "  make restart   - Restart the service"
	@echo "  make status    - Show service status and recent logs"
	@echo "  make logs      - Follow the log file"
	@echo "  make clean     - Remove build artifacts"
	@echo "  make help      - Show this help"
