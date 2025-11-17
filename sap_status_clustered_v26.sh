#!/bin/bash

# sap_status_clustered_v26.sh
# Show SAP cluster status including HANA SR, ASCS/ERS, SMDA
# Usage: ./sap_status_clustered_v26.sh [--owner] [--debug]

DEBUG=0
SHOW_OWNER=0

for arg in "$@"; do
    case $arg in
        --debug) DEBUG=1 ;;
        --owner) SHOW_OWNER=1 ;;
    esac
done

dbg() {
    if [[ "$DEBUG" -eq 1 ]]; then
        printf "DEBUG: %s\n" "$*" >&2
    fi
}

HOSTNAME=$(hostname -s)
echo -e "Hostname\tSID\tNr\tType\tRunning\tRole"$( [[ $SHOW_OWNER -eq 1 ]] && echo -e "\tOwner" )

# Function to detect running processes for a given sapcontrol
get_running_status() {
    local SAPCTL="$1"
    local SUDO_USER="$2"
    if [[ ! -x "$SAPCTL" ]]; then
        echo "No"
        return
    fi
    local OUT
    OUT=$(sudo -u "$SUDO_USER" "$SAPCTL" -function GetProcessList 2>/dev/null)
    if echo "$OUT" | grep -q '^OK'; then
        echo "Yes"
    else
        echo "No"
    fi
}

# Capture HANA SR output if available
HANASR_OUTPUT=""
if command -v SAPHanaSR-showAttr &>/dev/null; then
    dbg "Reading SAPHanaSR-showAttr"
    HANASR_OUTPUT=$(SAPHanaSR-showAttr 2>/dev/null)
fi

# Get all sapcontrol paths
SAPCONTROL_PATHS=$(ls -d /usr/sap/*/*/exe/sapcontrol 2>/dev/null)
for SAPCTL in $SAPCONTROL_PATHS; do
    INST_DIR=$(basename "$(dirname "$SAPCTL")")          # e.g., HDB00, ASCS00, ERS01, SMDA98
    SID=$(basename "$(dirname "$(dirname "$SAPCTL")")") # e.g., D3G, DAA, DA1
    TYPE="$INST_DIR"
    NR=$(echo "$INST_DIR" | grep -oE '[0-9]{2,}$' || echo "00")

    # Determine sap user
    SAP_USER=$(echo "$SID" | tr '[:upper:]' '[:lower:]')adm

    dbg "Parsed instance: SID=$SID INST_DIR=$INST_DIR TYPE=$TYPE NR=$NR"
    dbg "Using sudo -u $SAP_USER $SAPCTL -function GetProcessList"

    RUNNING=$(get_running_status "$SAPCTL" "$SAP_USER")

    # Determine Role from HANA SR if HDB
    ROLE="N/A"
    if [[ "$TYPE" =~ ^HDB ]]; then
        if [[ -n "$HANASR_OUTPUT" ]]; then
            HOST_SR_LINE=$(echo "$HANASR_OUTPUT" | grep -w "$HOSTNAME")
            if [[ -n "$HOST_SR_LINE" ]]; then
                CLONE_STATE=$(echo "$HOST_SR_LINE" | awk '{print $2}')
                SRMODE=$(echo "$HOST_SR_LINE" | awk '{print $12}')
                if [[ "$CLONE_STATE" == "PROMOTED" ]]; then
                    ROLE="PRIMARY"
                elif [[ "$CLONE_STATE" == "DEMOTED" ]]; then
                    ROLE="SECONDARY"
                else
                    ROLE="No SR"
                fi
            fi
        else
            ROLE="No SR"
        fi
    elif [[ "$TYPE" =~ ^ASCS|ERS|SMDA ]]; then
        ROLE="$TYPE"
    fi

    OWNER="$HOSTNAME"
    if [[ $SHOW_OWNER -eq 1 ]]; then
        # Check pacemaker for owner of resource
        if command -v crm_mon &>/dev/null; then
            RESOURCE_NAME="rsc_sap_${SID}_${TYPE}"
            OWNER_NODE=$(crm_resource -l | grep -A4 "$RESOURCE_NAME" | grep 'Started' | awk '{print $2}' | head -n1)
            [[ -n "$OWNER_NODE" ]] && OWNER="$OWNER_NODE"
        fi
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s" "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
    [[ $SHOW_OWNER -eq 1 ]] && printf "\t%s" "$OWNER"
    echo
done
