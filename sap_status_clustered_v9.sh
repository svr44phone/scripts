#!/usr/bin/env bash
# ------------------------------------------------------------
# sap_status_clustered_v9.sh
# SAP Instance & Cluster Status with optional --owner column
# Supports ASCS, ERS, App Servers, SMDA, HANA (SR)
# SLES15 version
# Owner behavior = B: PRIMARY host = SR primary, SECONDARY = local node
# ------------------------------------------------------------

dbg() { :; }

HOST=$(hostname -s)
SHOW_OWNER=0
[[ "$1" == "--owner" ]] && SHOW_OWNER=1

printf_header() {
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-6s %-4s %-12s %-10s %-12s %-20s\n" \
            "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
    else
        printf "%-20s %-6s %-4s %-12s %-10s %-12s\n" \
            "Hostname" "SID" "Nr" "Type" "Running" "Role"
    fi
}

printf_row() {
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-6s %-4s %-12s %-10s %-12s %-20s\n" \
            "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    else
        printf "%-20s %-6s %-4s %-12s %-10s %-12s\n" \
            "$1" "$2" "$3" "$4" "$5" "$6"
    fi
}

# ------------------------------------------------------------
# Get all instances from filesystem
# ------------------------------------------------------------
get_instances() {
    for inst in /usr/sap/*/*[0-9][0-9]; do
        [[ -d "$inst" ]] || continue
        SID=$(basename "$(dirname "$inst")")
        NR=$(echo "$inst" | grep -oE '[0-9][0-9]')
        TYPE_DIR=$(basename "$inst")

        # Normalize types
        case "$TYPE_DIR" in
            ASCS*) TYPE="ASCS$NR" ;;
            ERS*)  TYPE="ERS$NR" ;;
            HDB*)  TYPE="HDB$NR" ;;
            SMDA*) TYPE="SMDA$NR" ;;
            D*)    TYPE="D$NR" ;;
            *)     TYPE="$TYPE_DIR" ;;
        esac

        echo "$SID $NR $TYPE"
    done
}

# ------------------------------------------------------------
# SAPControl running state (HANA → must run as <sid>adm)
# ------------------------------------------------------------
get_running_state() {
    local SID=$1
    local NR=$2
    local TYPE=$3

    local LOWER_SID=$(echo "$SID" | tr '[:upper:]' '[:lower:]')

    local STATE
    if [[ "$TYPE" == HDB* ]]; then
        STATE=$(sudo -u ${LOWER_SID}adm sapcontrol -nr "$NR" -function GetProcessList 2>/dev/null)
    else
        STATE=$(sapcontrol -nr "$NR" -function GetProcessList 2>/dev/null)
    fi

    echo "$STATE" | grep -q "GREEN" && echo "Yes" && return
    echo "No"
}

# ------------------------------------------------------------
# HANA Role from SAPHanaSR-showAttr
# ------------------------------------------------------------
get_hana_role() {
    local SID=$1
    local NR=$2

    [[ "$TYPE" != HDB* ]] && echo "N/A" && return

    if ! command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
        echo "No SR"
        return
    fi

    local LINE
    LINE=$(SAPHanaSR-showAttr 2>/dev/null | grep -i "$HOST" | grep -i "$SID" | grep -i "$NR")

    [[ -z "$LINE" ]] && echo "No SR" && return

    local ROLE
    ROLE=$(echo "$LINE" | awk '{print $2}')

    case "$ROLE" in
        PROMOTED)  echo "PRIMARY" ;;
        DEMOTED)   echo "SECONDARY" ;;
        *)         echo "No SR" ;;
    esac
}

# ------------------------------------------------------------
# Owner logic (Option B)
# ------------------------------------------------------------
determine_owner() {
    local ROLE=$1
    local SID=$2
    local NR=$3

    if [[ "$ROLE" == "PRIMARY" ]]; then
        SAPHanaSR-showAttr 2>/dev/null | grep -i "PROMOTED" | grep -i "$SID" | awk '{print $1}'
        return
    fi

    # SECONDARY and No SR → local node
    echo "$HOST"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------
printf_header

get_instances | while read -r SID NR TYPE; do

    RUNNING=$(get_running_state "$SID" "$NR" "$TYPE")

    if [[ "$TYPE" == ASCS* ]]; then
        ROLE="ASCS"
    elif [[ "$TYPE" == ERS* ]]; then
        ROLE="ERS"
    elif [[ "$TYPE" == HDB* ]]; then
        ROLE=$(get_hana_role "$SID" "$NR")
    else
        ROLE="N/A"
    fi

    if [[ $SHOW_OWNER -eq 1 ]]; then
        OWNER=$(determine_owner "$ROLE" "$SID" "$NR")
        printf_row "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE" "$OWNER"
    else
        printf_row "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
    fi

done
