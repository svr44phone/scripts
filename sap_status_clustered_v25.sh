#!/bin/bash
# sap_status_clustered_v25.sh
# Shows SAP cluster status (HANA, ASCS, ERS, SMDA)
# Usage: ./sap_status_clustered_v25.sh [--owner] [--debug]

OWNER_FLAG=0
DEBUG=0

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --owner) OWNER_FLAG=1 ;;
        --debug) DEBUG=1 ;;
    esac
done

dbg() {
    if [[ "$DEBUG" -eq 1 ]]; then
        printf "DEBUG: %s\n" "$*" >&2
    fi
}

# Detect Pacemaker owner for a resource
get_owner() {
    local resource="$1"
    crm_resource -l | grep -E "^$resource\$" >/dev/null || return
    local owner
    owner=$(crm_resource -l | grep -A 5 "^$resource\$" | grep 'Started' | awk '{print $2}')
    echo "${owner:-N/A}"
}

# Print header
if [[ "$OWNER_FLAG" -eq 1 ]]; then
    printf "%-15s %-5s %-4s %-10s %-10s %-15s %-15s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-15s %-5s %-4s %-10s %-10s %-15s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

HOSTNAME=$(hostname -s)

# Read SAPHanaSR-showAttr output if available
if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
    dbg "Reading SAPHanaSR-showAttr"
    HANA_SR_OUTPUT=$(SAPHanaSR-showAttr 2>/dev/null)
else
    HANA_SR_OUTPUT=""
fi

# Loop over SAP instances
for SAPCTL in /usr/sap/*/*/exe/sapcontrol; do
    [[ -x "$SAPCTL" ]] || continue

    INST_DIR=$(basename "$(dirname "$SAPCTL")")        # e.g., ASCS00, ERS01, HDB00, SMDA98
    SID=$(basename "$(dirname "$(dirname "$SAPCTL")")") # e.g., D3G, DAA, DA1

    # Validate SID (3 chars)
    if [[ ! "$SID" =~ ^[A-Z0-9]{3}$ ]]; then
        dbg "Skipping invalid SID: $SID from $SAPCTL"
        continue
    fi

    # Validate instance type
    TYPE="$INST_DIR"
    NR=$(echo "$INST_DIR" | grep -oE '[0-9]{2,}$' || echo "")
    if [[ -z "$NR" ]]; then
        NR="00"
    fi

    RUNNING="No"
    ROLE="N/A"

    # Determine SAP instance status using sapcontrol
    USER="${SID,,}adm"  # lowercase SID + adm
    if sudo -u "$USER" "$SAPCTL" -nr "$NR" -function GetProcessList >/dev/null 2>&1; then
        RUNNING="Yes"
    else
        # connection refused or other error
        RUNNING="No"
    fi

    # Determine HANA SR role if SAPHanaSR-showAttr output exists
    if [[ -n "$HANA_SR_OUTPUT" ]] && [[ "$TYPE" =~ ^HDB ]]; then
        LINE=$(echo "$HANA_SR_OUTPUT" | grep -w "$SID")
        if [[ -n "$LINE" ]]; then
            if echo "$LINE" | grep -q "PROMOTED"; then
                ROLE="PRIMARY"
            elif echo "$LINE" | grep -q "DEMOTED"; then
                ROLE="SECONDARY"
            else
                ROLE="No SR"
            fi
        fi
    elif [[ "$TYPE" =~ ASCS|ERS ]]; then
        ROLE="$TYPE"
    fi

    OWNER="N/A"
    if [[ "$OWNER_FLAG" -eq 1 ]]; then
        # Determine cluster owner for ASCS/ERS/HANA
        RESOURCE_NAME=""
        if [[ "$TYPE" =~ ASCS|ERS ]]; then
            RESOURCE_NAME=$(crm_resource -l | grep -i "$INST_DIR" | head -n1)
        elif [[ "$TYPE" =~ HDB ]]; then
            RESOURCE_NAME=$(crm_resource -l | grep -i "msl_SAPHana_${SID}_$TYPE" | head -n1)
        fi

        if [[ -n "$RESOURCE_NAME" ]]; then
            OWNER=$(get_owner "$RESOURCE_NAME")
        fi
    fi

    # Print result
    if [[ "$OWNER_FLAG" -eq 1 ]]; then
        printf "%-15s %-5s %-4s %-10s %-10s %-15s %-15s\n" "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE" "$OWNER"
    else
        printf "%-15s %-5s %-4s %-10s %-10s %-15s\n" "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
    fi

done
