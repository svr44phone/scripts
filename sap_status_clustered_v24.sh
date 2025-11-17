#!/bin/bash

# -------------------------------------------------------------------
# SAP Cluster Status Script v24
# -------------------------------------------------------------------

DEBUG=0
SHOW_OWNER=0
HOST=$(hostname -s)

# parse args
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        --owner) SHOW_OWNER=1 ;;
    esac
done

# dbg()
dbg() {
    if [[ "$DEBUG" -eq 1 ]]; then
        printf "DEBUG: %s\n" "$*" >&2
    fi
}

# print header
if [[ "$SHOW_OWNER" -eq 1 ]]; then
    printf "%-15s %-5s %-4s %-12s %-10s %-10s %-15s\n" \
        "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-15s %-5s %-4s %-12s %-10s %-10s\n" \
        "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

# --------------------------------------
# Load SAPHanaSR-showAttr (if available)
# --------------------------------------
declare -A HANA_ROLE
declare -A HANA_RUNNING

if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
    dbg "Reading SAPHanaSR-showAttr"
    while read -r NODE STATE SCORE SYNC_STATE PRIMARY SECONDARY CONFIG _; do
        SID=$(echo "$CONFIG" | awk -F':' '{print $1}')
        if [[ "$SID" =~ ^[A-Z0-9]{3}$ ]]; then
            if [[ "$STATE" == "PROMOTED" ]]; then
                HANA_ROLE["$SID"]="Primary"
                HANA_RUNNING["$SID"]="Yes"
            else
                HANA_ROLE["$SID"]="Secondary"
                HANA_RUNNING["$SID"]="Yes"
            fi
        fi
    done < <(SAPHanaSR-showAttr 2>/dev/null || true)
fi

# --------------------------------------
# Discover only real SAP instances
# --------------------------------------

mapfile -t SAP_CTLS < <(find /usr/sap -path "*/exe/sapcontrol" -type f 2>/dev/null)

for SAPCTL in "${SAP_CTLS[@]}"; do

    INST_DIR=$(basename "$(dirname "$SAPCTL")")      # e.g. ASCS00
    SID=$(basename "$(dirname "$(dirname "$SAPCTL")")")  # e.g. D3G

    # SID must be exactly 3 uppercase letters/digits
    if [[ ! "$SID" =~ ^[A-Z0-9]{3}$ ]]; then
        dbg "Skipping invalid SID: $SID from $SAPCTL"
        continue
    fi

    # Instance directory must end with digits
    if [[ ! "$INST_DIR" =~ [0-9]{2,}$ ]]; then
        dbg "Skipping non-instance directory: $INST_DIR"
        continue
    fi

    NR=$(echo "$INST_DIR" | grep -o '[0-9]\+$')
    TYPE="$INST_DIR"

    ADM="${SID,,}adm"

    # -----------------------
    # Run sapcontrol
    # -----------------------
    dbg "Running sudo -u $ADM $SAPCTL -nr $NR -function GetProcessList"

    SAPOUT=$(sudo -u "$ADM" "$SAPCTL" -nr "$NR" -function GetProcessList 2>/dev/null)

    if echo "$SAPOUT" | grep -q "GREEN"; then
        RUNNING="Yes"
    else
        RUNNING="No"
    fi

    # -----------------------
    # Determine SAP Role
    # -----------------------
    ROLE="N/A"

    case "$TYPE" in
        ASCS*) ROLE="ASCS" ;;
        ERS*)  ROLE="ERS"  ;;
        HDB*)
            if [[ -n "${HANA_ROLE[$SID]}" ]]; then
                ROLE="${HANA_ROLE[$SID]}"
                RUNNING="${HANA_RUNNING[$SID]}"
            else
                ROLE="No SR"
            fi
            ;;
    esac

    # -----------------------
    # Determine Owner (Pacemaker)
    # -----------------------
    OWNER=""
    if [[ "$SHOW_OWNER" -eq 1 ]]; then
        OWNER=$(crm_resource --locate --resource "rsc_sap_${SID}_${TYPE}" 2>/dev/null | awk '{print $NF}' | head -n1)
        [[ -z "$OWNER" ]] && OWNER="$HOST"
    fi

    # -----------------------
    # Print line
    # -----------------------

    if [[ "$SHOW_OWNER" -eq 1 ]]; then
        printf "%-15s %-5s %-4s %-12s %-10s %-10s %-15s\n" \
            "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE" "$OWNER"
    else
        printf "%-15s %-5s %-4s %-12s %-10s %-10s\n" \
            "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
    fi

done
