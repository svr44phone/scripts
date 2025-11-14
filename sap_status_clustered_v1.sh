#!/bin/bash
# SAP Instance Status Report Script
# Works for HANA, NetWeaver (ENSA2 ASCS/ERS), App Servers, and SMDA/DAA Diagnostic Agents
# Cluster-aware HANA Primary/Secondary detection via SAPHanaSR-showAttr

set -euo pipefail

HOSTNAME=$(hostname)

# Output header
printf "%-15s %-5s %-5s %-10s %-10s %-12s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"

if [ ! -f /usr/sap/sapservices ]; then
    echo "No /usr/sap/sapservices found"
    exit 0
fi

# Iterate sapservices lines
grep -v '^#' /usr/sap/sapservices | grep "/usr/sap/" | while read -r line; do
    # Extract the profile path from "pf=" param
    PROFILE=$(echo "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p')
    [ -z "$PROFILE" ] && continue

    # SID is folder after /usr/sap/
    SID=$(echo "$PROFILE" | awk -F'/' '{print $4}')

    # Instance type/number from second element of profile name
    INSTANCE_PART=$(basename "$PROFILE" | awk -F'_' '{print $2}')
    INSTANCE_NUMBER=${INSTANCE_PART: -2}
    INSTANCE_TYPE=${INSTANCE_PART%$INSTANCE_NUMBER}

    INSTANCE_PATH="/usr/sap/$SID/${INSTANCE_TYPE}${INSTANCE_NUMBER}"
    RUNNING="No"
    ROLE="N/A"

    # Check via sapcontrol or special-case SMDA
    if [[ -x "$INSTANCE_PATH/exe/sapcontrol" ]]; then
        if [[ "$INSTANCE_TYPE" == SMDA* ]]; then
            # Diagnostics Agent check via process list
            if pgrep -f "${INSTANCE_TYPE}${INSTANCE_NUMBER}" >/dev/null || \
               pgrep -f "sapstartsrv.*SMDA${INSTANCE_NUMBER}" >/dev/null; then
                RUNNING="Yes"
            fi
        else
            STATE=$("$INSTANCE_PATH/exe/sapcontrol" -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
            if echo "$STATE" | grep -q "GREEN"; then
                RUNNING="Yes"
            elif echo "$STATE" | grep -q "YELLOW"; then
                RUNNING="Degraded"
            fi

            # ------------------ HANA SR Role Detection ------------------
            if [[ "$INSTANCE_TYPE" == "HDB" ]]; then
                if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
                    HANASR=$(SAPHanaSR-showAttr 2>/dev/null | grep -E "^$HOSTNAME[[:space:]]")
                    CLONE_STATE=$(echo "$HANASR" | awk '{print $2}')
                    case "$CLONE_STATE" in
                        PROMOTED)
                            ROLE="Primary"
                            ;;
                        DEMOTED)
                            ROLE="Secondary"
                            ;;
                        *)
                            ROLE="No SR"
                            ;;
                    esac
                elif [[ -x "$INSTANCE_PATH/HDB$INSTANCE_NUMBER/exe/hdbnsutil" ]]; then
                    SR_STATE=$(su - "${SID,,}adm" -c "$INSTANCE_PATH/HDB$INSTANCE_NUMBER/exe/hdbnsutil -sr_state" 2>/dev/null || true)
                    if echo "$SR_STATE" | grep -q "mode: primary"; then
                        ROLE="Primary"
                    elif echo "$SR_STATE" | grep -q "mode: secondary"; then
                        ROLE="Secondary"
                    else
                        ROLE="No SR"
                    fi
                fi
            fi

            # ------------------ ENSA2 ASCS/ERS ------------------
            if [[ "$INSTANCE_TYPE" == ASCS* ]]; then
                ROLE="ASCS"
            elif [[ "$INSTANCE_TYPE" == ERS* ]]; then
                ROLE="ERS"
            fi

            # ------------------ Application Server Active/Passive ------------------
            if [[ "$INSTANCE_TYPE" =~ ^D[0-9]{2}$ ]]; then
                DISP_GREEN=$(echo "$STATE" | grep -i dispatcher | grep -c GREEN)
                DIA_GREEN=$(echo "$STATE" | grep -i DIA | grep -c GREEN)

                if [[ $DISP_GREEN -gt 0 && $DIA_GREEN -gt 0 ]]; then
                    ROLE="Active"
                elif [[ $DISP_GREEN -gt 0 && $DIA_GREEN -eq 0 ]]; then
                    ROLE="Passive"
                else
                    ROLE="Down"
                fi
            fi
        fi
    else
        # Fallback to process check if no sapcontrol
        if pgrep -f "${INSTANCE_TYPE}${INSTANCE_NUMBER}" >/dev/null; then
            RUNNING="Yes"
        fi
    fi

    printf "%-15s %-5s %-5s %-10s %-10s %-12s\n" \
        "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INSTANCE_TYPE" "$RUNNING" "$ROLE"
done
