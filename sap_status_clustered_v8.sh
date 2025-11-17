#!/usr/bin/env bash
#
# sap_status_clustered_v8.sh
#
# SAP Instance Status + Cluster Ownership (ASCS / ERS / HANA)
# OWNER BEHAVIOR (v8):
#   - ASCS/ERS  -> actual Pacemaker host running the resource
#   - HANA      -> master host (primary)
#   - everything else -> local host
#
# No coloring.
#

HOST=$(hostname -s)
SHOW_OWNER=0

if [[ "$1" == "--owner" ]]; then
    SHOW_OWNER=1
fi

# ------------------------------------------------------------
# No-op debug function
# ------------------------------------------------------------
dbg() { :; }

# ------------------------------------------------------------
# Cluster parsing functions (Pacemaker)
# ------------------------------------------------------------
crm_output=""
if command -v crm_mon >/dev/null 2>&1; then
    crm_output=$(crm_mon -1 -r 2>/dev/null)
fi

get_cluster_owner() {
    local PATTERN=$1

    echo "$crm_output" \
        | grep -E "$PATTERN" \
        | sed -E 's/.*Started[[:space:]]+([A-Za-z0-9._-]+).*/\1/' \
        | head -n1
}

# ------------------------------------------------------------
# Extract cluster owner for HANA primary
# ------------------------------------------------------------
get_hana_primary_owner() {
    local SID=$1
    local HANA_NAME="SAPHana_${SID}_HDB00"

    # Newer clusters show: "Masters: [ node1 ]"
    local master
    master=$(echo "$crm_output" | grep -A2 -E "msl_${SID}_HDB00|${HANA_NAME}" | grep -E "Master|Masters" | sed -E 's/.*\[\s*([A-Za-z0-9._-]+).*/\1/' | head -n1)

    [[ -n "$master" ]] && echo "$master"
}

# ------------------------------------------------------------
# SAP instance discovery
# ------------------------------------------------------------
get_sap_instances() {
    for inst in /usr/sap/*/*[0-9][0-9]; do
        [[ -d "$inst" ]] || continue
        SID=$(basename "$(dirname "$inst")")
        NR=$(echo "$inst" | grep -oE '[0-9][0-9]')
        BASE=$(basename "$inst" | tr '[:lower:]' '[:upper:]')

        case "$BASE" in
            ASCS*) TYPE="ASCS$NR" ;;
            ERS*)  TYPE="ERS$NR" ;;
            HDB*)  TYPE="HDB$NR" ;;
            DAA*)  TYPE="SMDA$NR" ;;
            SCS*)  TYPE="SCS$NR" ;;         # Windows-like SCS
            DVEBM*) TYPE="D$NR" ;;          # App server
            *) TYPE="$BASE" ;;
        esac

        echo "$SID $NR $TYPE"
    done
}

# ------------------------------------------------------------
# Running state via SAPControl
# ------------------------------------------------------------
get_running_state() {
    local NR=$1
    sapcontrol -nr "$NR" -function GetProcessList 2>/dev/null | grep -q GREEN
    [[ $? -eq 0 ]] && echo "Yes" || echo "No"
}

# ------------------------------------------------------------
# HANA role via SAPHanaSR-showAttr
# ------------------------------------------------------------
get_hana_role() {
    local SID=$1
    local NR=$2

    if ! command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
        echo "No SR"
        return
    fi

    local out
    out=$(SAPHanaSR-showAttr 2>/dev/null | grep -i "$HOST" | grep -i "$SID" | grep -i "$NR")

    [[ -z "$out" ]] && { echo "No SR"; return; }

    echo "$out" | awk '{print $2}' \
        | sed -e 's/PROMOTED/PRIMARY/' \
              -e 's/DEMOTED/SECONDARY/'
}

# ------------------------------------------------------------
# Output formatting
# ------------------------------------------------------------
print_header() {
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-6s %-4s %-12s %-10s %-15s %-20s\n" \
            "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
    else
        printf "%-20s %-6s %-4s %-12s %-10s %-15s\n" \
            "Hostname" "SID" "Nr" "Type" "Running" "Role"
    fi
}

print_row() {
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-6s %-4s %-12s %-10s %-15s %-20s\n" \
            "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    else
        printf "%-20s %-6s %-4s %-12s %-10s %-15s\n" \
            "$1" "$2" "$3" "$4" "$5" "$6"
    fi
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------
print_header

get_sap_instances | while read -r SID NR TYPE; do
    RUNNING=$(get_running_state "$NR")
    ROLE="N/A"
    OWNER="$HOST"      # default owner = local host

    case "$TYPE" in
        ASCS*)
            ROLE="ASCS"
            OWNER=$(get_cluster_owner "rsc_sap_${SID}_ASCS${NR}")
            [[ -z "$OWNER" ]] && OWNER="$HOST"
            ;;
        ERS*)
            ROLE="ERS"
            OWNER=$(get_cluster_owner "rsc_sap_${SID}_ERS${NR}")
            [[ -z "$OWNER" ]] && OWNER="$HOST"
            ;;
        HDB*)
            ROLE=$(get_hana_role "$SID" "$NR")

            if [[ "$ROLE" == "PRIMARY" ]]; then
                OWNER=$(get_hana_primary_owner "$SID")
                [[ -z "$OWNER" ]] && OWNER="$HOST"
            else
                OWNER="$HOST"   # secondary owns itself
            fi
            ;;
    esac

    print_row "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE" "$OWNER"

done
