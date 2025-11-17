#!/bin/bash
# SAP Instance Status Report Script v19
# Works for HANA, NetWeaver (ASCS/ERS), App Servers, SMDA/DAA Diagnostic Agents
# Cluster-aware HANA Primary/Secondary detection via SAPHanaSR-showAttr
# Pacemaker-aware ASCS/ERS owner detection
# SLES 15 compatible

set -euo pipefail

HOSTNAME=$(hostname -s)
SHOW_OWNER=0
DEBUG=0

for arg in "$@"; do
    case "$arg" in
        --owner) SHOW_OWNER=1 ;;
        --debug) DEBUG=1 ;;
    esac
done

# Pacemaker owner cache
declare -A OWNER_CACHE
if [[ $SHOW_OWNER -eq 1 ]] && command -v crm >/dev/null 2>&1; then
    CRM_STATUS=$(crm status | awk '/Resource Group:|rsc_sap/ {print $0}')
    while read -r line; do
        if [[ $line =~ rsc_sap.*ASCS([0-9]{2}) ]]; then
            RSC=$(echo "$line" | awk '{print $1}')
            OWNER_CACHE["ASCS${BASH_REMATCH[1]}"]=$(echo "$line" | awk '{print $NF}')
        elif [[ $line =~ rsc_sap.*ERS([0-9]{2}) ]]; then
            RSC=$(echo "$line" | awk '{print $1}')
            OWNER_CACHE["ERS${BASH_REMATCH[1]}"]=$(echo "$line" | awk '{print $NF}')
        fi
    done <<< "$CRM_STATUS"
fi

# Output header
if [[ $SHOW_OWNER -eq 1 ]]; then
    printf "%-15s %-5s %-5s %-10s %-10s %-12s %-15s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-15s %-5s %-5s %-10s %-10s %-12s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

if [[ ! -f /usr/sap/sapservices ]]; then
    echo "No /usr/sap/sapservices found"
    exit 0
fi

# Iterate sapservices lines
grep -v '^#' /usr/sap/sapservices | grep "/usr/sap/" | while read -r line; do
    PROFILE=$(echo "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p')
    [ -z "$PROFILE" ] && continue

    SID=$(echo "$PROFILE" | awk -F'/' '{print $4}')
    INSTANCE_PART=$(basename "$PROFILE" | awk -F'_' '{print $2}')
    INSTANCE_NUMBER=${INSTANCE_PART: -2}
    INSTANCE_TYPE=${INSTANCE_PART%$INSTANCE_NUMBER}
    INSTANCE_DIR="$INSTANCE_TYPE$INSTANCE_NUMBER"
    INSTANCE_PATH="/usr/sap/$SID/$INSTANCE_DIR"

    RUNNING="No"
    ROLE="N/A"
    OWNER="$HOSTNAME"

    if [[ -x "$INSTANCE_PATH/exe/sapcontrol" ]]; then
        if [[ "$INSTANCE_TYPE" == SMDA* ]]; then
            if pgrep -f "${INSTANCE_DIR}" >/dev/null; then
                RUNNING="Yes"
            fi
        elif [[ "$INSTANCE_TYPE" == ASCS* || "$INSTANCE_TYPE" == ERS* ]]; then
            # NetWeaver ASCS/ERS
            STATE=$("$INSTANCE_PATH/exe/sapcontrol" -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
            if echo "$STATE" | grep -q GREEN; then
                RUNNING="Yes"
            fi
            ROLE="$INSTANCE_TYPE"
            if [[ $SHOW_OWNER -eq 1 && -n "${OWNER_CACHE[$INSTANCE_DIR]:-}" ]]; then
                OWNER="${OWNER_CACHE[$INSTANCE_DIR]}"
            fi
        elif [[ "$INSTANCE_TYPE" =~ ^D[0-9]{2}$ ]]; then
            # Application Server
            STATE=$("$INSTANCE_PATH/exe/sapcontrol" -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
            DISP_GREEN=$(echo "$STATE" | grep -i dispatcher | grep -c GREEN)
            DIA_GREEN=$(echo "$STATE" | grep -i DIA | grep -c GREEN)
            if [[ $DISP_GREEN -gt 0 && $DIA_GREEN -gt 0 ]]; then
                RUNNING="Yes"
                ROLE="Active"
            elif [[ $DISP_GREEN -gt 0 && $DIA_GREEN -eq 0 ]]; then
                RUNNING="Yes"
                ROLE="Passive"
            else
                RUNNING="No"
                ROLE="Down"
            fi
        elif [[ "$INSTANCE_TYPE" == HDB* ]]; then
            # HANA
            STATE=$("$INSTANCE_PATH/exe/sapcontrol" -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
            if echo "$STATE" | grep -q GREEN; then
                RUNNING="Yes"
            elif echo "$STATE" | grep -q YELLOW; then
                RUNNING="Degraded"
            else
                RUNNING="No"
            fi

            if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
                HANASR=$(SAPHanaSR-showAttr 2>/dev/null | grep -E "^$HOSTNAME[[:space:]]")
                CLONE_STATE=$(echo "$HANASR" | awk '{print $2}')
                case "$CLONE_STATE" in
                    PROMOTED) ROLE="PRIMARY" ;;
                    DEMOTED)  ROLE="SECONDARY" ;;
                    *)        ROLE="No SR" ;;
                esac
            fi
        fi
    else
        # fallback process check
        if pgrep -f "${INSTANCE_DIR}" >/dev/null; then
            RUNNING="Yes"
        fi
    fi

    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-15s %-5s %-5s %-10s %-10s %-12s %-15s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INSTANCE_DIR" "$RUNNING" "$ROLE" "$OWNER"
    else
        printf "%-15s %-5s %-5s %-10s %-10s %-12s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INSTANCE_DIR" "$RUNNING" "$ROLE"
    fi

    [[ $DEBUG -eq 1 ]] && echo "DEBUG: Parsed instance: SID=$SID INST_DIR=$INSTANCE_DIR TYPE=$INSTANCE_TYPE NR=$INSTANCE_NUMBER"
done
