#!/bin/bash
# sap_status_clustered_v29.sh
DEBUG=0
SHOW_OWNER=0

for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        --owner) SHOW_OWNER=1 ;;
    esac
done

dbg() { [[ "$DEBUG" -eq 1 ]] && printf "DEBUG: %s\n" "$*" >&2; }

HOSTNAME=$(hostname -s)

# Capture HANA SR state
HANASR_OUTPUT=$(SAPHanaSR-showAttr 2>/dev/null)
dbg "Captured SAPHanaSR-showAttr output"

# Build Pacemaker resource -> node map
declare -A RESOURCE_OWNER
while read -r line; do
    RESOURCE=$(echo "$line" | awk '{print $1}')
    NODE=$(echo "$line" | awk '{print $3}')
    RESOURCE_OWNER[$RESOURCE]=$NODE
done < <(crm_resource -l 2>/dev/null | while read r; do
    crm_resource -W -r "$r" 2>/dev/null | grep "Started" || true
done)

printf "%-15s %-6s %-6s %-10s %-8s %-10s" "Hostname" "SID" "Nr" "Type" "Running" "Role"
[[ "$SHOW_OWNER" -eq 1 ]] && printf " %-15s" "Owner"
printf "\n"

SAPCONTROL_PATHS=$(find /usr/sap -type f -name sapcontrol 2>/dev/null)
[[ -z "$SAPCONTROL_PATHS" ]] && { echo "No sapcontrol found"; exit 1; }

for SAPCTL in $SAPCONTROL_PATHS; do
    INST_PATH=$(dirname "$SAPCTL")
    INST_DIR=$(basename "$INST_PATH")
    SID=$(basename "$(dirname "$INST_PATH")")

    case "$INST_DIR" in
        HDB*) TYPE="HDB" ;;
        ASCS*) TYPE="ASCS" ;;
        ERS*) TYPE="ERS" ;;
        SMDA*) TYPE="SMDA" ;;
        *) TYPE="Unknown" ;;
    esac

    NR=$(echo "$INST_DIR" | grep -oE '[0-9]{2,}$' || echo "00")
    SAP_USER=$(echo "$SID" | tr '[:upper:]' '[:lower:]')adm
    dbg "Parsed instance: SID=$SID INST_DIR=$INST_DIR TYPE=$TYPE NR=$NR"

    # Determine owner node for ASCS/ERS and HANA ERS
    OWNER="$HOSTNAME"
    if [[ "$TYPE" == "ASCS" || "$TYPE" == "ERS" ]]; then
        RES_NAME=$(basename "$INST_PATH" | tr '[:upper:]' '[:lower:]')
        for R in "${!RESOURCE_OWNER[@]}"; do
            if [[ "$R" =~ $RES_NAME ]]; then
                OWNER=${RESOURCE_OWNER[$R]}
                break
            fi
        done
    elif [[ "$TYPE" == "HDB" && "$INST_DIR" == *"ERS"* ]]; then
        # Determine ERS owner from SAPHanaSR-showAttr
        ERS_LINE=$(echo "$HANASR_OUTPUT" | grep -w "$SID")
        [[ -n "$ERS_LINE" ]] && OWNER=$(echo "$ERS_LINE" | awk '{print $6}')
    fi

    # Determine running status
    RUNNING="No"
    if [[ "$OWNER" == "$HOSTNAME" ]]; then
        if sudo -u "$SAP_USER" "$SAPCTL" -nr "$NR" -function GetProcessList &>/dev/null; then
            RUNNING="Yes"
        fi
    else
        # Remote check could be added with ssh if desired
        RUNNING="No"
    fi

    # Determine role
    ROLE="N/A"
    if [[ "$TYPE" == "HDB" ]]; then
        HOST_SR_LINE=$(echo "$HANASR_OUTPUT" | grep -w "$HOSTNAME" | grep -w "$SID")
        if [[ -n "$HOST_SR_LINE" ]]; then
            CLONE_STATE=$(echo "$HOST_SR_LINE" | awk '{print $2}')
            if [[ "$CLONE_STATE" == "PROMOTED" ]]; then
                ROLE="PRIMARY"
            elif [[ "$CLONE_STATE" == "DEMOTED" ]]; then
                ROLE="SECONDARY"
            else
                ROLE="No SR"
            fi
        else
            ROLE="No SR"
        fi
    elif [[ "$TYPE" == "ASCS" ]]; then
        ROLE="ASCS"
    elif [[ "$TYPE" == "ERS" ]]; then
        ROLE="ERS"
    fi

    [[ "$SHOW_OWNER" -eq 1 ]] && printf "%-15s %-6s %-6s %-10s %-8s %-10s %-15s\n" \
        "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE" "$OWNER" || \
        printf "%-15s %-6s %-6s %-10s %-8s %-10s\n" \
        "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
done
