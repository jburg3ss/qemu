#!/usr/bin/env bash

################################################################################
# init.sh                                                                      #
#                                                                              #
# Unified script for launching VMs with different configurations.              #
# Use config files to define VM behavior (minimal, standard, custom).          #
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DISK_DIR="${PROJECT_ROOT}/disc"
IMAGE_DIR="${PROJECT_ROOT}/image"
CONFIG_DIR="${PROJECT_ROOT}/config"
LOG_DIR="${PROJECT_ROOT}/logs"

show_logo() {
    cat << "EOF"

  ____  _____ __  __ _   _ 
 / __ \|  ___||  \/  | | | |
| |  | | |__  | |\/| | | | |
| |  | |  __| | |  | | | | |
| |__| | |___ | |  | | |_| |
 \___\_\_____||_|  |_|\___/ 
                            
    VM Initialization Script
EOF
    echo ""
}

show_help() {
    show_logo
    cat << EOF
Usage: $(basename "$0") -c CONFIG [OPTIONS]

Launch QEMU VMs using configuration files.

REQUIRED:
    -c, --config PATH       Path to config file (e.g., config/windows-minimal.conf)

OPTIONS:
    -i, --iso PATH          Path to ISO file (overrides config default)
    -m, --memory SIZE       Memory in MB (overrides config default)
    -p, --cpus COUNT        Number of CPUs (overrides config default)
    -s, --size SIZE         Disk size (overrides config default)
    -n, --name SUFFIX       Custom name suffix (default: random word)
    -h, --help              Show this help message

EXAMPLES:
    # Install new Windows VM
    $(basename "$0") -c config/windows-standard.conf -i image/win11.iso -n base

    # Run malware analysis (snapshot mode)
    $(basename "$0") -c config/windows-minimal.conf -n base

    # Custom Linux VM with more resources
    $(basename "$0") -c config/linux-standard.conf -i image/ubuntu.iso -m 8192 -p 8

AVAILABLE CONFIGS:
EOF
    
    # List available config files
    if [ -d "$CONFIG_DIR" ]; then
        for conf in "$CONFIG_DIR"/*.conf; do
            [ -f "$conf" ] && echo "    - $(basename "$conf")"
        done
    fi
    
    echo ""
    exit 0
}

# Check if no arguments provided
if [ $# -eq 0 ]; then
    show_help
fi

# Initialize variables
CONFIG_FILE=""
OVERRIDE_ISO=""
OVERRIDE_MEMORY=""
OVERRIDE_CPUS=""
OVERRIDE_DISK_SIZE=""
CUSTOM_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -i|--iso)
            OVERRIDE_ISO="$2"
            shift 2
            ;;
        -m|--memory)
            OVERRIDE_MEMORY="$2"
            shift 2
            ;;
        -p|--cpus)
            OVERRIDE_CPUS="$2"
            shift 2
            ;;
        -s|--size)
            OVERRIDE_DISK_SIZE="$2"
            shift 2
            ;;
        -n|--name)
            CUSTOM_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Validate config file is provided
if [ -z "$CONFIG_FILE" ]; then
    echo "Error: Config file required. Use -c to specify a config file."
    echo ""
    show_help
fi

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Show logo when launching VM
show_logo

# Load config file
echo "Loading config: $CONFIG_FILE"
source "$CONFIG_FILE"

# Apply overrides (CLI args take precedence over config)
MEMORY="${OVERRIDE_MEMORY:-$DEFAULT_MEMORY}"
CPUS="${OVERRIDE_CPUS:-$DEFAULT_CPUS}"
DISK_SIZE="${OVERRIDE_DISK_SIZE:-$DEFAULT_DISK_SIZE}"
ISO="${OVERRIDE_ISO:-$DEFAULT_ISO}"

# Generate hostname
if [ -z "$CUSTOM_NAME" ]; then
    HOST_NAME=$(shuf -n 1 /usr/share/dict/words | tr -d "'" | tr '[:upper:]' '[:lower:]')
else
    HOST_NAME="$CUSTOM_NAME"
fi

# Build VM name
VM_NAME="${VM_PREFIX}-${HOST_NAME}"
DISK="${DISK_DIR}/${VM_NAME}.qcow2"

# Setup logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/${VM_NAME}_${TIMESTAMP}.log"

# Display configuration
echo ""
echo "=========================================="
echo "VM Configuration"
echo "=========================================="
echo "Name:     $VM_NAME"
echo "Type:     $VM_TYPE"
echo "Memory:   ${MEMORY}MB"
echo "CPUs:     $CPUS"
echo "Disk:     $DISK"
[ -n "$ISO" ] && echo "ISO:      $ISO"
echo "Snapshot: $SNAPSHOT"
echo "Network:  $NETWORK"
echo "Log:      $LOG_FILE"
echo "=========================================="
echo ""

# Create directories if they don't exist
mkdir -p "$DISK_DIR"
mkdir -p "$LOG_DIR"

# Create disk if doesn't exist
if [ ! -f "$DISK" ]; then
    echo "Creating new disk: $DISK ($DISK_SIZE)"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
    echo ""
fi

# Build QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -name "$VM_NAME"
    -m "$MEMORY"
    -smp "$CPUS"
    -cpu host
    -enable-kvm
)

# Add disk with snapshot mode if configured
if [ "$SNAPSHOT" = "on" ]; then
    QEMU_CMD+=(-drive "file=$DISK,format=qcow2,snapshot=on")
else
    QEMU_CMD+=(-drive "file=$DISK,format=qcow2")
fi

# Add ISO if provided
if [ -n "$ISO" ]; then
    QEMU_CMD+=(-cdrom "$ISO")
fi

# Add network configuration
if [ "$NETWORK" = "none" ]; then
    QEMU_CMD+=(-net none)
elif [ "$NETWORK" = "user" ]; then
    QEMU_CMD+=(-net nic,model=virtio -net user,hostname="$VM_NAME")
fi

# Add display and graphics
QEMU_CMD+=(-vga virtio)
QEMU_CMD+=(-display "${DISPLAY:-gtk}")

# Add boot configuration
if [ -n "$ISO" ]; then
    QEMU_CMD+=(-boot d)  # Boot from CD-ROM first
else
    QEMU_CMD+=(-boot c)  # Boot from hard disk
fi

# Add hostname configuration
QEMU_CMD+=(-fw_cfg name=opt/hostname,string="$VM_NAME")

# Configure logging based on VM type
# Standard VMs: Basic logging (errors and warnings)
# Minimal VMs: Verbose logging (for malware analysis and forensics)
if [ "$VM_TYPE" = "minimal" ]; then
    # Verbose logging for malware analysis
    # Logs: guest errors, CPU resets, interrupts, page faults
    QEMU_CMD+=(-D "$LOG_FILE")
    QEMU_CMD+=(-d guest_errors,cpu_reset,int,page)
else
    # Basic logging for standard VMs
    # Logs: guest errors only
    QEMU_CMD+=(-D "$LOG_FILE")
    QEMU_CMD+=(-d guest_errors)
fi

# Write session info to log
{
    echo "=========================================="
    echo "QEMU VM Session Log"
    echo "=========================================="
    echo "Date:       $(date)"
    echo "VM Name:    $VM_NAME"
    echo "VM Type:    $VM_TYPE"
    echo "Config:     $CONFIG_FILE"
    echo "Memory:     ${MEMORY}MB"
    echo "CPUs:       $CPUS"
    echo "Snapshot:   $SNAPSHOT"
    echo "Network:    $NETWORK"
    echo "Disk:       $DISK"
    [ -n "$ISO" ] && echo "ISO:        $ISO"
    echo "=========================================="
    echo ""
} >> "$LOG_FILE"

# Display command (for debugging)
if [ "${DEBUG:-0}" = "1" ]; then
    echo "QEMU Command:"
    printf '%s\n' "${QEMU_CMD[@]}"
    echo ""
fi

# Launch VM
echo "Launching VM..."
echo "Logs will be written to: $LOG_FILE"
echo ""
"${QEMU_CMD[@]}"

# Log session end
echo "" >> "$LOG_FILE"
echo "Session ended: $(date)" >> "$LOG_FILE"
