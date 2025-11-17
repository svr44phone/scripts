#!/bin/bash
# sap_status_clustered_v20.sh
# Checks SAP instances including HANA and ASCS/ERS in a clustered environment
# Usage: ./sap_status_clustered_v20.sh [--owner] [--debug]

set -euo pipefail

DEBUG=0
SHOW_OWNER=0

for arg in "$@"; do
    case $arg in
        --debug) DEBUG=1 ;;
        --owner) SHOW_OWNER=1 ;;
        *) ;;
    esac
done

dbg() { $DEBUG && echo "DEBUG: $*"; }

HOSTNAME=$(hostname -s)
printf '%-15s %-5s %-5s %-10s %-10s' "Hostname" "SID" "Nr" "Type" "Running"
$SHOW_OWNER && printf ' %-12s' "Owner"
printf ' %-10s\n' "Role"

# --- Gather cluster info for ASCS/ERS ---
declare -A RESOURCE_OWNER
if command -v crm &>/dev/null; then
    crm_mon -1 -r | awk '
    /Resource Group:/ {group=$3}
    /rsc_sap_/ && /Started/ {gsub(/^[* ]+|$/,"",$3); print group,$3,$5}
    ' | while read grp res node; do
        RESOURCE_OWNER[$res]=$node
    done
fi

# --- Gather SAPHanaSR output for HANA nodes ---
declare -A HANA_ROLE HANA_RUNNING
if command -v SAPHanaSR-showAttr &>/dev/null; then
    SAPHanaSR-showAttr | awk -v host="$HOSTNAME" '
    /^Hosts/ {flag=1; next} flag && $0 ~ host {
        sid=$1; state=$2; srmode=$11;
        running="No"; if(state=="PROMOTED") running="Yes";
        print sid,running,srmode
    }
    ' | while read sid running srmode; do
        HANA_ROLE[$sid]=$srmode
        HANA_RUNNING[$sid]=$running
    done
fi

# --- Iterate /usr/sap/*/*/exe/sapcontrol ---
for SC in /usr/sap/*/*/exe/sapcontrol; do
    INSTANCE_PATH=$(dirname "$SC")
    SID=$(echo "$INSTANCE_PATH" | awk -F/ '{print $3}')
    INST_DIR=$(basename "$INSTANCE_PATH")
    INSTANCE_NR=$(echo "$INST_DIR" | grep -o '[0-9]\+')
    TYPE=$(echo "$INST_DIR" | sed "s/[0-9]\+//")
    RUNNING="No"
    ROLE="N/A"
    OWNER="$HOSTNAME"

    # HANA instances
    if [[ $TYPE =~ HDB ]]; then
        RUNNING="${HANA_RUNNING[$SID]:-No}"
        ROLE="${HANA_ROLE[$SID]:-No SR}"
    fi

    # ASCS/ERS instances, check Pacemaker owner
    if [[ $TYPE =~ ASCS|ERS ]]; then
        RES_NAME="rsc_sap_${SID}_${INST_DIR}"
        OWNER="${RESOURCE_OWNER[$RES_NAME]:-$HOSTNAME}"
        # Attempt local sapcontrol check
        if sudo -u ${SID,,}adm "$SC" -nr "$INSTANCE_NR" -function GetProcessList &>/dev/null; then
            RUNNING="Yes"
        fi
        ROLE="$TYPE"
    fi

    # Other instances (SMDA, app servers)
    if [[ $TYPE =~ SMDA ]]; then
        if sudo -u ${SID,,}adm "$SC" -nr "$INSTANCE_NR" -function GetProcessList &>/dev/null; then
            RUNNING="Yes"
        fi
    fi

    dbg "Parsed instance: SID=$SID INST_DIR=$INST_DIR TYPE=$TYPE NR=$INSTANCE_NR"
    dbg "Running=$RUNNING Role=$ROLE Owner=$OWNER"

    printf '%-15s %-5s %-5s %-10s %-10s' "$HOSTNAME" "$SID" "$INSTANCE_NR" "$TYPE" "$RUNNING"
    $SHOW_OWNER && printf ' %-12s' "$OWNER"
    printf ' %-10s\n' "$ROLE"
done
