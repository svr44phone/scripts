#!/bin/bash
# sap_status_clustered_v30.sh
# Show SAP clustered instance status with correct Type, Running, Role, Owner

DEBUG=0
OWNER=0

# Parse options
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        --owner) OWNER=1 ;;
    esac
done

dbg() {
    [[ "$DEBUG" -eq 1 ]] && printf "DEBUG: %s\n" "$*" >&2
}

HOSTNAME=$(hostname -s)

# Explicit instance mapping
declare -A INSTANCE_TYPE NR_MAPPING SAP_USER_MAPPING

# HANA DB
INSTANCE_TYPE[D3G_HDB00]="HDB"
NR_MAPPING[D3G_HDB00]="00"
SAP_USER_MAPPING[D3G_HDB00]="d3gadm"

INSTANCE_TYPE[H4C_HDB96]="HDB"
NR_MAPPING[H4C_HDB96]="96"
SAP_USER_MAPPING[H4C_HDB96]="h4cadm"

INSTANCE_TYPE[DAA_SMDA98]="SMDA"
NR_MAPPING[DAA_SMDA98]="98"
SAP_USER_MAPPING[DAA_SMDA98]="daaadm"

INSTANCE_TYPE[DA1_SMDA97]="SMDA"
NR_MAPPING[DA1_SMDA97]="97"
SAP_USER_MAPPING[DA1_SMDA97]="da1adm"

# ASCS/ERS
INSTANCE_TYPE[D3G_ASCS00]="ASCS"
NR_MAPPING[D3G_ASCS00]="00"
SAP_USER_MAPPING[D3G_ASCS00]="d3gadm"

INSTANCE_TYPE[D3G_ERS01]="ERS"
NR_MAPPING[D3G_ERS01]="01"
SAP_USER_MAPPING[D3G_ERS01]="d3gadm"

# Collect SAPCONTROL paths
SAPCONTROL_PATHS=$(find /usr/sap -type f -name sapcontrol 2>/dev/null)

printf "%-15s %-6s %-6s %-10s %-8s" "Hostname" "SID" "Nr" "Type" "Running"
[[ "$OWNER" -eq 1 ]] && printf " %-10s" "Role"
[[ "$OWNER" -eq 1 ]] && printf " %-10s" "Owner"
printf "\n"

for SAPCTL in $SAPCONTROL_PATHS; do
    INST_PATH=$(dirname "$SAPCTL")
    INST_DIR=$(basename "$INST_PATH")
    SID=$(basename "$(dirname "$INST_PATH")")
    KEY="${SID}_${INST_DIR}"

    TYPE=${INSTANCE_TYPE[$KEY]:-Unknown}
    NR=${NR_MAPPING[$KEY]:-00}
    SAP_USER=${SAP_USER_MAPPING[$KEY]:-root}

    [[ "$TYPE" == "Unknown" ]] && { dbg "Skipping unknown instance $KEY from $SAPCTL"; continue; }

    dbg "Parsed instance: SID=$SID INST_DIR=$INST_DIR TYPE=$TYPE NR=$NR SAP_USER=$SAP_USER"

    # Determine Running
    RUNNING="No"
    if sudo -u "$SAP_USER" "$SAPCTL" -nr "$NR" -function GetProcessList &>/dev/null; then
        RUNNING="Yes"
    fi

    # Determine Role
    ROLE="N/A"
    if [[ "$TYPE" == "HDB" ]]; then
        # Try reading SAPHanaSR-showAttr for role
        if command -v SAPHanaSR-showAttr &>/dev/null; then
            ROLE_LINE=$(SAPHanaSR-showAttr | grep -E "^$SID\b")
            [[ -n "$ROLE_LINE" ]] && ROLE=$(echo "$ROLE_LINE" | awk '{print $5}')
        fi
    elif [[ "$TYPE" == "ASCS" || "$TYPE" == "ERS" ]]; then
        # Pacemaker resource owner
        RES_NAME=$(crm_resource -l | grep -i "$SID" | head -n1)
        if [[ -n "$RES_NAME" ]]; then
            OWNER_NODE=$(crm_resource -l "$RES_NAME" -q 2>/dev/null | grep "Started" | awk '{print $2}')
            [[ -n "$OWNER_NODE" ]] && ROLE=$SID
        fi
    fi

    printf "%-15s %-6s %-6s %-10s %-8s" "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING"
    [[ "$OWNER" -eq 1 ]] && printf " %-10s %-10s" "$ROLE" "$HOSTNAME"
    printf "\n"
done
