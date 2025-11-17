#!/bin/bash
# sap_status_clustered_v38.sh
# Detect SAP instances (HANA, ASCS, ERS, APP) with running status and role

DEBUG=0
SHOW_OWNER=0

for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        --owner) SHOW_OWNER=1 ;;
    esac
done

dbg() {
    [[ $DEBUG -eq 1 ]] && printf "DEBUG: %s\n" "$*" >&2
}

HOSTNAME=$(hostname -s)
printf "Hostname\tSID\tNr\tType\tRunning\tRole"
[[ $SHOW_OWNER -eq 1 ]] && printf "\tOwner"
echo

declare -A INSTANCES

# === 1. Detect HANA instances from /usr/sap/*/*/exe/hdb* and /usr/sap/*/*/exe/sapcontrol
for SAPCTL in /usr/sap/*/*/exe/sapcontrol; do
    [[ -x "$SAPCTL" ]] || continue

    DIR=$(dirname "$SAPCTL")
    SID=$(basename $(dirname "$DIR"))
    NR=$(basename "$DIR" | grep -o '[0-9][0-9]' || echo "00")
    OWNER="${SID,,}adm"
    INSTANCES["$SID-$NR"]="$SAPCTL,$OWNER,HDB"
done

# === 2. Detect ASCS/ERS from sapcontrol in standard exe directories
for SAPCTL in /usr/sap/*/*/exe/sapcontrol; do
    [[ -x "$SAPCTL" ]] || continue
    OWNER=$(basename $(dirname $(dirname "$SAPCTL")) | tr '[:upper:]' '[:lower:]')adm
    # Skip if already HANA
    SID=$(basename $(dirname $(dirname "$SAPCTL")))
    NR=$(basename $(dirname "$SAPCTL") | grep -o '[0-9][0-9]' || echo "00")
    TYPE="APP"

    PROC=$(sudo -u "$OWNER" "$SAPCTL" -nr "$NR" -function GetProcessList 2>/dev/null)
    if echo "$PROC" | grep -iq "msg_server"; then
        TYPE="ASCS"
    elif echo "$PROC" | grep -iq "enq_replicator"; then
        TYPE="ERS"
    else
        TYPE="APP"
    fi

    INSTANCES["$SID-$NR"]="$SAPCTL,$OWNER,$TYPE"
done

# === 3. Detect additional app instances from /usr/sap/sapservices
if [[ -f /usr/sap/sapservices ]]; then
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" =~ SAP([A-Z0-9]{2,})_([0-9]{2}) ]]; then
            SID="${BASH_REMATCH[1]}"
            NR="${BASH_REMATCH[2]}"
            OWNER="${SID,,}adm"
            [[ -z "${INSTANCES["$SID-$NR"]}" ]] && INSTANCES["$SID-$NR"]="$line,$OWNER,APP"
        fi
    done < /usr/sap/sapservices
fi

# === 4. Function to determine running status and role
determine_running_role() {
    local SAPCTL="$1"
    local OWNER="$2"
    local TYPE="$3"
    local SID="$4"

    [[ ! -x "$SAPCTL" ]] && echo "No N/A" && return

    PROC_OUT=$(sudo -u "$OWNER" "$SAPCTL" -function GetProcessList 2>/dev/null)
    dbg "sapcontrol output for $SAPCTL: $PROC_OUT"

    RUNNING="No"
    ROLE="N/A"

    case "$TYPE" in
        HDB)
            [[ "$PROC_OUT" =~ GREEN ]] && RUNNING="Yes"
            if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
                SR=$(SAPHanaSR-showAttr | grep "$HOSTNAME" | grep "$SID" 2>/dev/null)
                if [[ "$SR" =~ PROMOTED ]]; then
                    ROLE="PRIMARY"
                elif [[ "$SR" =~ DEMOTED ]]; then
                    ROLE="SECONDARY"
                else
                    ROLE="NONE"
                fi
            else
                ROLE="NONE"
            fi
            ;;
        ASCS)
            [[ "$PROC_OUT" =~ Running ]] && RUNNING="Yes"
            ROLE="ASCS"
            ;;
        ERS)
            [[ "$PROC_OUT" =~ Running ]] && RUNNING="Yes"
            ROLE="ERS"
            ;;
        APP)
            [[ "$PROC_OUT" =~ Running ]] && RUNNING="Yes"
            ROLE="APP"
            ;;
    esac

    echo "$RUNNING" "$ROLE"
}

# === 5. Print all instances
for key in "${!INSTANCES[@]}"; do
    IFS=',' read -r SAPCTL OWNER TYPE <<< "${INSTANCES[$key]}"
    SID="${key%%-*}"
    NR="${key#*-}"

    read RUNNING ROLE <<< $(determine_running_role "$SAPCTL" "$OWNER" "$TYPE" "$SID")
    printf "%s\t%s\t%s\t%s\t%s\t%s" "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
    [[ $SHOW_OWNER -eq 1 ]] && printf "\t%s" "$OWNER"
    echo
done
