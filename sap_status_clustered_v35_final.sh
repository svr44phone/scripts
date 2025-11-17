#!/bin/bash
DEBUG=${DEBUG:-0}
HOST=$(hostname -s)

dbg() {
    [[ "$DEBUG" -eq 1 ]] && printf "DEBUG: %s\n" "$*" >&2
}

printf "%-15s %-6s %-4s %-10s %-8s %-10s %-10s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"

# Function to check HANA SR role
hana_sr_role() {
    local sid="$1"
    local inst_dir="$2"
    local owner="$3"
    local role="N/A"

    if command -v SAPHanaSR-showAttr &>/dev/null; then
        SR_OUT=$(SAPHanaSR-showAttr | grep "$HOST")
        SR_ROLE=$(echo "$SR_OUT" | awk -v sid="$sid" '$2==sid {print $2,$12}' | awk '{print $2}')
        [[ -n "$SR_ROLE" ]] && role="$SR_ROLE"
    fi
    echo "$role"
}

grep -vE '^\s*#' /usr/sap/sapservices | while read -r LINE; do
    [[ -z "$LINE" ]] && continue
    SID="UNKNOWN"
    NR="00"
    TYPE="APP"
    OWNER="UNKNOWNadm"
    RUNNING="No"
    ROLE="N/A"

    # sapstartsrv path
    SAPSTART=$(echo "$LINE" | grep -o '/usr/sap/[^ ]*/[^ ]*/exe/sapstartsrv')
    if [[ -n "$SAPSTART" ]]; then
        PATH_PARTS=(${SAPSTART//\// })
        SID=${PATH_PARTS[3]:-UNKNOWN}
        INST_DIR=${PATH_PARTS[4]:-UNKNOWN}
        NR=$(echo "$INST_DIR" | grep -o '[0-9]\+' || echo "00")
        TYPE="APP"
        [[ "$INST_DIR" =~ HDB ]] && TYPE="HDB"
        [[ "$INST_DIR" =~ ASCS ]] && TYPE="ASCS"
        [[ "$INST_DIR" =~ ERS ]]  && TYPE="ERS"
        [[ "$INST_DIR" =~ SMDA ]] && TYPE="SMDA"
        OWNER="${SID}adm"

        # Check if HANA DB for SR role
        if [[ "$TYPE" == "HDB" || "$TYPE" == "SMDA" ]]; then
            ROLE=$(hana_sr_role "$SID" "$INST_DIR" "$OWNER")
        else
            ROLE="$TYPE"
        fi

        [[ -x "$SAPSTART" ]] && sudo -u "$OWNER" "$SAPSTART" -function GetProcessList &>/dev/null && RUNNING="Yes"
    fi

    # systemctl app server lines
    if [[ "$LINE" =~ systemctl[[:space:]]+--no-ask-password[[:space:]]+start[[:space:]]+(SAP[A-Z0-9_]+) ]]; then
        SERVICE_NAME=${BASH_REMATCH[1]}
        if [[ "$SERVICE_NAME" =~ ^SAP([A-Z0-9]+)_([0-9]+)$ ]]; then
            SID=${BASH_REMATCH[1]}
            NR=${BASH_REMATCH[2]}
            TYPE="APP"
            OWNER="${SID}adm"
            ROLE="$TYPE"
            systemctl is-active --quiet "$SERVICE_NAME" && RUNNING="Yes"
        fi
    fi

    printf "%-15s %-6s %-4s %-10s %-8s %-10s %-10s\n" "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE" "$OWNER"
    dbg "Parsed instance: SID=$SID INST_DIR=${INST_DIR:-UNKNOWN} TYPE=$TYPE NR=$NR OWNER=$OWNER ROLE=$ROLE PATH=$SAPSTART LINE=$LINE"
done
