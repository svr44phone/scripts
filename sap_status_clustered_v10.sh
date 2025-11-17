#!/bin/bash

SHOW_OWNER=0
[ "$1" == "--owner" ] && SHOW_OWNER=1

HOSTNAME=$(hostname -s)

printf "%-20s %-6s %-4s %-12s %-10s %-12s" "Hostname" "SID" "Nr" "Type" "Running" "Role"
[ $SHOW_OWNER -eq 1 ] && printf " %-20s" "Owner"
printf "\n"

# ---------------------------------------------------------------------
# Detect Pacemaker owners for resources (ASCS, ERS, HANA VIP)
# ---------------------------------------------------------------------

declare -A OWNER_MAP

if command -v crm >/dev/null 2>&1; then
    while read -r RES TYPE OWNER; do
        OWNER_MAP["$RES"]="$OWNER"
    done < <(crm_resource --list | awk '/Started/{print $1, $2, $NF}')
fi

# ---------------------------------------------------------------------
# Helper: determine instance owner for ASCS/ERS or HANA VIP
# ---------------------------------------------------------------------

get_owner() {
    local sid="$1"
    local nr="$2"

    # For ASCS/ERS style resources
    for RES in "${!OWNER_MAP[@]}"; do
        if [[ "$RES" == *"${sid}_ASCS${nr}"* ]] || [[ "$RES" == *"${sid}_ERS${nr}"* ]]; then
            echo "${OWNER_MAP[$RES]}"
            return
        fi
    done

    # HANA: VIP resource (rsc_ip_SID_HDBNR)
    for RES in "${!OWNER_MAP[@]}"; do
        if [[ "$RES" == *"${sid}_HDB${nr}"* ]] && [[ "$RES" == rsc_ip_* ]]; then
            echo "${OWNER_MAP[$RES]}"
            return
        fi
    done

    echo "$HOSTNAME"
}

# ---------------------------------------------------------------------
# Process each SID installed on system
# ---------------------------------------------------------------------

for SAPSID in $(ls /usr/sap | grep -vE 'hostctrl|sapservices'); do

    for INST in /usr/sap/$SAPSID/*; do
        INST_NR=$(basename "$INST" | sed 's/^[A-Z]*//')
        INST_TYPE=$(basename "$INST")

        case "$INST_TYPE" in
            ASCS*) TYPE="ASCS" ;;
            ERS*)  TYPE="ERS" ;;
            HDB*)  TYPE="HDB${INST_NR}" ;;
            SMDA*) TYPE="SMDA${INST_NR}" ;;
            *) continue ;;
        esac

        # Detect correct sapcontrol binary
        SAPCONTROL_PATH="/usr/sap/$SAPSID/$INST_TYPE/exe/sapcontrol"
        if [ ! -x "$SAPCONTROL_PATH" ]; then
            RUNNING="No"
            ROLE="N/A"
            OWNER="$HOSTNAME"
        else
            OUT=$("$SAPCONTROL_PATH" -nr "$INST_NR" -function GetProcessList 2>/dev/null)

            if echo "$OUT" | grep -q ",GREEN,"; then
                RUNNING="Yes"
            else
                RUNNING="No"
            fi

            # Determine role for HANA
            if [[ "$TYPE" == HDB* ]]; then
                if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
                    ROLE=$(SAPHanaSR-showAttr | grep "$HOSTNAME" | awk '{print $9}')
                    [ -z "$ROLE" ] && ROLE="No SR"
                else
                    ROLE="No SR"
                fi
            else
                ROLE="N/A"
            fi

            # Owner
            if [ $SHOW_OWNER -eq 1 ]; then
                OWNER=$(get_owner "$SAPSID" "$INST_NR")
            fi
        fi

        printf "%-20s %-6s %-4s %-12s %-10s %-12s" "$HOSTNAME" "$SAPSID" "$INST_NR" "$TYPE" "$RUNNING" "$ROLE"
        [ $SHOW_OWNER -eq 1 ] && printf " %-20s" "$OWNER"
        printf "\n"

    done
done
