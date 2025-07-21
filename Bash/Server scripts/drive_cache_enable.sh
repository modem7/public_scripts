#!/bin/bash

# UnRAID SATA Write Cache Enable Script
# Optimized for SATA HDDs and SSDs only
# Uses smartctl as primary method with hdparm fallback

echo "=== UnRAID SATA Write Cache Enable Script ==="
echo "Starting at $(date)"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
total_drives=0
success_count=0
failed_count=0
unsupported_count=0

# Check if required tools are available
check_tools() {
    local missing_tools=()
    
    if ! command -v smartctl &> /dev/null; then
        missing_tools+=("smartctl (smartmontools)")
    fi
    if ! command -v hdparm &> /dev/null; then
        missing_tools+=("hdparm")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing required tools: ${missing_tools[*]}${NC}"
        echo "Please install missing packages before running this script."
        exit 1
    fi
}

# Function to get drive info (model and type)
get_drive_info() {
    local drive=$1
    local model=""
    local rotation=""
    
    # Get drive model and rotation rate
    if command -v smartctl &> /dev/null; then
        model=$(smartctl -i "$drive" 2>/dev/null | grep "Device Model\|Model Number" | head -1 | cut -d: -f2 | xargs)
        rotation=$(smartctl -i "$drive" 2>/dev/null | grep "Rotation Rate" | cut -d: -f2 | xargs)
        
        if [ -n "$model" ]; then
            if echo "$rotation" | grep -qi "solid state\|0 rpm"; then
                echo "($model - SSD)"
            elif echo "$rotation" | grep -qi "[0-9]* rpm"; then
                echo "($model - HDD)"
            else
                echo "($model)"
            fi
            return
        fi
    fi
    
    echo "(Unknown SATA drive)"
}

# Function to check current write cache status
check_current_status() {
    local drive=$1
    
    # Try smartctl first (more reliable)
    if command -v smartctl &> /dev/null; then
        smart_output=$(smartctl -g wcache "$drive" 2>/dev/null)
        if echo "$smart_output" | grep -qi "write cache.*enabled\|write cache.*on"; then
            echo "ON"
            return
        elif echo "$smart_output" | grep -qi "write cache.*disabled\|write cache.*off"; then
            echo "OFF"
            return
        fi
    fi
    
    # Fallback to hdparm
    hdparm_output=$(hdparm -W "$drive" 2>/dev/null | grep "write-caching" | tail -1)
    if echo "$hdparm_output" | grep -q "write-caching.*1 (on)"; then
        echo "ON"
    elif echo "$hdparm_output" | grep -q "write-caching.*0 (off)"; then
        echo "OFF"
    else
        echo "UNKNOWN"
    fi
}

# Function to enable write cache using smartctl
try_smartctl() {
    local drive=$1
    
    echo -e "    ${CYAN}Method 1: smartctl -s wcache,on${NC}"
    output=$(smartctl -s wcache,on "$drive" 2>&1)
    
    # Check for success indicators
    if echo "$output" | grep -qi "write cache.*enabled\|successfully set\|completed without error"; then
        return 0  # Success
    elif echo "$output" | grep -qi "not supported\|not implemented\|invalid field"; then
        echo -e "    ${YELLOW}smartctl: Write cache control not supported${NC}"
        return 2  # Not supported
    elif echo "$output" | grep -qi "permission denied\|operation not permitted"; then
        echo -e "    ${RED}smartctl: Permission denied (try as root)${NC}"
        return 1  # Failed
    else
        # Try SCT method for drives that might need it
        echo -e "    ${CYAN}Method 1b: smartctl -s wcache-sct,on,p${NC}"
        sct_output=$(smartctl -s wcache-sct,on,p "$drive" 2>&1)
        
        if echo "$sct_output" | grep -qi "write cache.*enabled\|successfully set\|completed without error"; then
            return 0  # Success
        elif echo "$sct_output" | grep -qi "not supported\|not implemented"; then
            return 2  # Not supported
        else
            return 1  # Failed
        fi
    fi
}

# Function to enable write cache using hdparm
try_hdparm() {
    local drive=$1
    
    echo -e "    ${CYAN}Method 2: hdparm -W 1${NC}"
    output=$(hdparm -W 1 "$drive" 2>&1)
    
    if echo "$output" | grep -q "write-caching.*1 (on)"; then
        return 0  # Success
    elif echo "$output" | grep -q "not supported"; then
        echo -e "    ${YELLOW}hdparm: Write cache not supported${NC}"
        return 2  # Not supported
    elif echo "$output" | grep -q "SG_IO.*bad/missing sense data"; then
        echo -e "    ${YELLOW}hdparm: Communication error (likely not supported)${NC}"
        return 2  # Not supported
    elif echo "$output" | grep -qi "permission denied\|operation not permitted"; then
        echo -e "    ${RED}hdparm: Permission denied (try as root)${NC}"
        return 1  # Failed
    else
        # Sometimes hdparm needs a retry
        echo -e "    ${CYAN}Method 2b: hdparm retry${NC}"
        sleep 1
        retry_output=$(hdparm -W 1 "$drive" 2>&1)
        if echo "$retry_output" | grep -q "write-caching.*1 (on)"; then
            return 0  # Success
        else
            return 1  # Failed
        fi
    fi
}

# Function to verify final status
verify_final_status() {
    local drive=$1
    local status
    
    status=$(check_current_status "$drive")
    case "$status" in
        "ON")
            echo -e "    ${GREEN}✓ Final status: Write cache ENABLED${NC}"
            return 0
            ;;
        "OFF")
            echo -e "    ${RED}✗ Final status: Write cache DISABLED${NC}"
            return 1
            ;;
        *)
            echo -e "    ${YELLOW}? Final status: Unable to verify${NC}"
            return 2
            ;;
    esac
}

# Main processing function for each drive
process_drive() {
    local drive=$1
    local drive_info
    local current_status
    local success=false
    
    drive_info=$(get_drive_info "$drive")
    current_status=$(check_current_status "$drive")
    
    echo -e "${BLUE}Processing $drive $drive_info${NC}"
    echo -e "    Current status: $current_status"
    
    # Skip if already enabled
    if [ "$current_status" = "ON" ]; then
        echo -e "    ${GREEN}✓ Write cache already enabled - skipping${NC}"
        success_count=$((success_count + 1))
        echo
        return
    fi
    
    # Check if drive exists and is accessible
    if [ ! -b "$drive" ]; then
        echo -e "    ${RED}✗ Not a valid block device${NC}"
        failed_count=$((failed_count + 1))
        echo
        return
    fi
    
    # Try smartctl first (preferred for SATA)
    case $(try_smartctl "$drive") in
        0) 
            echo -e "    ${GREEN}✓ Success via smartctl${NC}"
            success=true
            ;;
        2) 
            # smartctl says not supported, but try hdparm anyway
            ;;
        *) 
            # smartctl failed, continue to hdparm
            ;;
    esac
    
    # Try hdparm if smartctl didn't succeed
    if ! $success; then
        case $(try_hdparm "$drive") in
            0) 
                echo -e "    ${GREEN}✓ Success via hdparm${NC}"
                success=true
                ;;
            2) 
                echo -e "    ${YELLOW}⚠ Both methods report not supported${NC}"
                unsupported_count=$((unsupported_count + 1))
                echo
                return
                ;;
            *) 
                # Both methods failed
                ;;
        esac
    fi
    
    # Final verification and status update
    if $success; then
        if verify_final_status "$drive"; then
            success_count=$((success_count + 1))
        else
            echo -e "    ${RED}✗ Command succeeded but verification failed${NC}"
            failed_count=$((failed_count + 1))
        fi
    else
        echo -e "    ${RED}✗ All methods failed${NC}"
        failed_count=$((failed_count + 1))
    fi
    
    echo
}

# Main execution
echo "Checking for required tools..."
check_tools
echo

# Get list of all SATA drives (whole drives only, not partitions)
drives=$(ls /dev/sd[a-z] 2>/dev/null | sort)

if [ -z "$drives" ]; then
    echo -e "${RED}No SATA drives found matching /dev/sd[a-z]${NC}"
    exit 1
fi

echo "Found SATA drives: $(echo $drives | tr '\n' ' ')"
echo

# Process each drive
for drive in $drives; do
    total_drives=$((total_drives + 1))
    process_drive "$drive"
done

# Final summary
echo "════════════════════════════════════════"
echo "                 SUMMARY"
echo "════════════════════════════════════════"
echo -e "Total SATA drives:      ${BLUE}$total_drives${NC}"
echo -e "Write cache enabled:    ${GREEN}$success_count${NC}"
echo -e "Not supported:          ${YELLOW}$unsupported_count${NC}"
echo -e "Failed to enable:       ${RED}$failed_count${NC}"
echo
echo "Completed at $(date)"

# Specific advice for SATA drives
if [ $failed_count -gt 0 ] || [ $unsupported_count -gt 0 ]; then
    echo
    echo "════════════════════════════════════════"
    echo "          SATA-SPECIFIC NOTES"
    echo "════════════════════════════════════════"
    echo "For SATA drives that couldn't enable write cache:"
    echo
    echo "HDDs (Traditional Hard Drives):"
    echo "• Most HDDs support write cache - failures usually indicate:"
    echo "  - Drive connected via USB/external enclosure"
    echo "  - SATA controller blocking low-level commands"
    echo "  - Drive firmware bug or very old drive"
    echo
    echo "SSDs (Solid State Drives):"
    echo "• Some enterprise SSDs disable write cache by design"
    echo "• Consumer SSDs usually support it but some firmware blocks it"
    echo "• NVMe drives use different commands (not applicable here)"
    echo
    echo "Troubleshooting:"
    echo "• Run: smartctl -c /dev/sdX | grep -i cache"
    echo "• Check: dmesg | grep -E 'sd[a-z]' | tail -10"
    echo "• Verify: lsblk -d -o NAME,TRAN /dev/sd*"
    echo
    echo "To make persistent: Add this script to /boot/config/go"
fi

# Performance note
if [ $success_count -gt 0 ]; then
    echo
    echo "════════════════════════════════════════"
    echo "            IMPORTANT NOTE"
    echo "════════════════════════════════════════"
    echo -e "${YELLOW}Write cache enabled on $success_count drive(s)${NC}"
    echo
    echo "Benefits: Faster write operations, especially for small files"
    echo "Risk: Potential data loss if power fails before cache is flushed"
    echo
    echo "Recommendations:"
    echo "• Ensure you have a UPS (Uninterruptible Power Supply)"
    echo "• Monitor drive temperatures - write cache can increase heat"
    echo "• Test performance with your typical workload"
fi
