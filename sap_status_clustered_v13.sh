#!/usr/bin/env bash
# sap_status_clustered_v13.sh
# Cluster-aware SAP instance status
# Works on SLES 15 with HANA, NetWeaver ASCS/ERS, App Servers, SMDA/DAA
# Detects HANA SR roles and Pacemaker owner

set -euo pipefail

# -------------------------
# CLI parsing
# -------------------------
SHOW_OWNER=0
DEBUG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --owner) SHOW_OWNER=1; shift ;;
        --debug) DEBUG=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

dbg() {
    if [[ "$DEBUG" -eq 1 ]]; then
        printf "DEBUG: %s\n" "$*" >&2
    fi
}

HOSTNAME=$(hostname -s)
SAPSERVICES="/usr/sap/sapservices"

# -------------------------
# Pacemaker owner cache
# -------------------------
declare -A OWNER_MAP
if [[ "$SHOW_OWNER" -eq 1 ]] && command -v crm >/dev/null 2>&1; then
    while read -r line; do
        [[ "$line" =~ rsc_sapstartsrv_([A-Z0-9]+)_[0-9]{2}.*Started[[:space:]]([a-zA-Z0-9_-]+) ]] || continue
        SID="${BASH_REMATCH[1]}"
        OWNER="${BASH_REMATCH[2]}"
        OWNER_MAP["$SID"]="$OWNER"
    done < <(crm_mon -1 -r 2>/dev/null | grep rsc_sapstartsrv)
fi

# -------------------------
# Output header
# -------------------------
if [[ "$SHOW_OWNER" -eq 1 ]]; then
    printf "%-15s %-5s %-5s %-10s %-10s %-12s %-15s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-15s %-5s %-5s %-10s %-10s %-12s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

# -------------------------
# Iterate sapservices
# -------------------------
[[ -f "$SAPSERVICES" ]] || exit 0

grep -v '^#' "$SAPSERVICES" | grep "/usr/sap/" | while read -r line; do
    PROFILE=$(echo "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p')
    [ -z "$PROFILE" ] && continue

    SID=$(echo "$PROFILE" | awk -F/ '{print $4}')
    INSTANCE_PART=$(basename "$PROFILE" | awk -F_ '{print $2}')
    INSTANCE_NUMBER=${INSTANCE_PART: -2}
    INSTANCE_TYPE=${INSTANCE_PART%$INSTANCE_NUMBER}
    INST_DIR="${INSTANCE_TYPE}${INSTANCE_NUMBER}"
    INSTANCE_PATH="/usr/sap/$SID/$INST_DIR"

    RUNNING="No"
    ROLE="N/A"
    OWNER="$HOSTNAME"

    # Detect ASCS/ERS HANA/SMDA instances
    SAPCONTROL="$INSTANCE_PATH/exe/sapcontrol"
    SIDADM="${SID,,}adm"

    if [[ -x "$SAPCONTROL" ]]; then
        dbg "Parsed instance: SID=$SID INST_DIR=$INST_DIR TYPE=$INSTANCE_TYPE NR=$INSTANCE_NUMBER"
        dbg "Using sudo -u $SIDADM $SAPCONTROL -nr $INSTANCE_NUMBER -function GetProcessList"

        STATE_OUT=$(sudo -u "$SIDADM" "$SAPCONTROL" -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
        dbg "sapcontrol output: $STATE_OUT"

        if [[ "$INSTANCE_TYPE" == SMDA* ]]; then
            # SMDA diagnostics agent
            if pgrep -f "${INST_DIR}" >/dev/null || pgrep -f "sapstartsrv.*${INST_DIR}" >/dev/null; then
                RUNNING="Yes"
            fi

        elif [[ "$INSTANCE_TYPE" =~ ^ASCS|ERS ]]; then
            # ASCS/ERS check
            DISP_GREEN=$(echo "$STATE_OUT" | grep -i dispatcher | grep -c GREEN || true)
            DIA_GREEN=$(echo "$STATE_OUT" | grep -i DIA | grep -c GREEN || true)
            if [[ $DISP_GREEN -gt 0 && $DIA_GREEN -gt 0 ]]; then
                RUNNING="Yes"
            elif [[ $DISP_GREEN -gt 0 || $DIA_GREEN -gt 0 ]]; then
                RUNNING="Degraded"
            else
                RUNNING="No"
            fi
            ROLE="$INSTANCE_TYPE"

        elif [[ "$INSTANCE_TYPE" == HDB* ]]; then
            # HANA instance
            if echo "$STATE_OUT" | grep -q GREEN; then
                RUNNING="Yes"
            elif echo "$STATE_OUT" | grep -q YELLOW; then
                RUNNING="Degraded"
            fi

            # HANA SR role detection
            if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
                HANASR=$(SAPHanaSR-showAttr 2>/dev/null | grep -E "^$HOSTNAME[[:space:]]")
                CLONE_STATE=$(echo "$HANASR" | awk '{print $2}')
                case "$CLONE_STATE" in
                    PROMOTED) ROLE="PRIMARY" ;;
                    DEMOTED) ROLE="SECONDARY" ;;
                    *) ROLE="No SR" ;;
                esac
            fi
        fi
    else
        # fallback if no sapcontrol
        if pgrep -f "${INST_DIR}" >/dev/null; then
            RUNNING="Yes"
        fi
    fi

    # Determine Pacemaker owner if requested
    if [[ "$SHOW_OWNER" -eq 1 ]] && [[ -n "${OWNER_MAP[$SID]:-}" ]]; then
        OWNER="${OWNER_MAP[$SID]}"
    fi

    # Print output
    if [[ "$SHOW_OWNER" -eq 1 ]]; then
        printf "%-15s %-5s %-5s %-10s %-10s %-12s %-15s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INST_DIR" "$RUNNING" "$ROLE" "$OWNER"
    else
        printf "%-15s %-5s %-5s %-10s %-10s %-12s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INST_DIR" "$RUNNING" "$ROLE"
    fi
done
