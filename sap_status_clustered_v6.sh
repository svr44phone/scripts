#!/usr/bin/env bash
#
# sap_status_clustered_v6.sh
# Cluster-aware SAP instance status reporter (v6)
# - HANA SR via SAPHanaSR-showAttr (preferred)
# - Uses su - <sidadm> -c "sapcontrol ..." when available
# - Optional --owner column (shows local host for HANA rows; ASCS/ERS owner from crm_mon)
# - Optional --debug for troubleshooting
#
# Usage:
#   ./sap_status_clustered_v6.sh [--owner] [--debug]
#

set -euo pipefail

# CLI flags
SHOW_OWNER=0
DEBUG=0

for a in "$@"; do
    case "$a" in
        --owner) SHOW_OWNER=1 ;;
        --debug) DEBUG=1 ;;
        *) ;;
    esac
done

SAPSERVICES="/usr/sap/sapservices"
HOSTNAME=$(hostname)

dbg() {
    $DEBUG && printf "DEBUG: %s\n" "$*" >&2
}

# safe command runner (no exit on error)
safe_run() {
    "$@" 2>/dev/null || true
}

# run sapcontrol as sidadm if possible (preferred on cluster nodes)
run_sapcontrol_as_sidadm() {
    local sid="$1"
    local nr="$2"
    local sid_lc
    sid_lc=$(echo "$sid" | tr 'A-Z' 'a-z')
    if id "${sid_lc}adm" >/dev/null 2>&1; then
        dbg "Running sapcontrol as ${sid_lc}adm for ${sid} nr ${nr}"
        # Use su - to ensure environment for sidadm
        safe_run su - "${sid_lc}adm" -c "sapcontrol -nr ${nr} -function GetProcessList"
    else
        dbg "sidadm not found for ${sid}, trying sapcontrol in PATH"
        if command -v sapcontrol >/dev/null 2>&1; then
            safe_run sapcontrol -nr "$nr" -function GetProcessList
        else
            echo ""
        fi
    fi
}

# Populate ASCS/ERS resource owner map from crm_mon if --owner requested
declare -A RESOURCE_OWNER   # key: like D3G_ASCS00 -> owner hostname

if [[ $SHOW_OWNER -eq 1 ]]; then
    if command -v crm_mon >/dev/null 2>&1; then
        dbg "Collecting cluster resources via crm_mon"
        CRM_OUT=$(crm_mon -1 -r 2>/dev/null || true)
        # Parse lines like:
        #   rsc_sap_D3G_ASCS00 (ocf::...):    Started azlsapd3ger01
        while IFS= read -r l; do
            if [[ "$l" =~ rsc_sap_([A-Za-z0-9_]+)[[:space:]]*\(.*\):[[:space:]]*Started[[:space:]]+([A-Za-z0-9._-]+) ]]; then
                key="${BASH_REMATCH[1]}"   # e.g. D3G_ASCS00
                owner="${BASH_REMATCH[2]}"
                RESOURCE_OWNER["$key"]="$owner"
                dbg "Found resource owner: $key -> $owner"
            fi
        done <<< "$CRM_OUT"

        # Additionally, try to parse HANA clone master/slave if present (msl_SAPHana... lines)
        # Example block in crm_mon: "Clone Set: msl_SAPHana_D3G_HDB00 [rsc_SAPHana_D3G_HDB00] (promotable):"
        # and subsequent lines list Masters: [ node ] / Slaves: [ node ]
        # We capture "Masters:" and "Slaves:" lines
        while IFS= read -r l; do
            if [[ "$l" =~ ^[[:space:]]*\*?[[:space:]]*Masters:[[:space:]]*\[?[[:space:]]*([A-Za-z0-9._-]+) ]]; then
                hana_master="${BASH_REMATCH[1]}"
                dbg "HANA master detected: $hana_master"
                HANA_MASTER_NODE="$hana_master"
            fi
            if [[ "$l" =~ ^[[:space:]]*\*?[[:space:]]*Slaves:[[:space:]]*\[?[[:space:]]*([A-Za-z0-9._-]+) ]]; then
                hana_slave="${BASH_REMATCH[1]}"
                dbg "HANA slave detected: $hana_slave"
                HANA_SLAVE_NODE="$hana_slave"
            fi
        done <<< "$CRM_OUT"
    else
        dbg "crm_mon not found; --owner will have limited info for ASCS/ERS"
    fi
fi

# Output header
if [[ $SHOW_OWNER -eq 1 ]]; then
    printf "%-20s %-6s %-4s %-12s %-10s %-12s %-20s\n" \
        "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-20s %-6s %-4s %-12s %-10s %-12s\n" \
        "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

# Validate sapservices
if [[ ! -f "$SAPSERVICES" ]]; then
    echo "No $SAPSERVICES found" >&2
    exit 0
fi

# Read sapservices line-by-line (avoid pipe subshell)
while IFS= read -r line || [[ -n "${line:-}" ]]; do
    # skip comments and empty lines and lines without /usr/sap/
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *"/usr/sap/"* ]] && continue

    # extract pf= value
    PROFILE=$(echo "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p' || true)
    [[ -z "$PROFILE" ]] && continue
    # strip quotes if any
    PROFILE="${PROFILE%\"}"
    PROFILE="${PROFILE#\"}"
    PROFILE="${PROFILE%\'}"
    PROFILE="${PROFILE#\'}"

    # SID and instance token
    SID=$(echo "$PROFILE" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="sap"){print $(i+1); exit}}')
    [[ -z "$SID" ]] && continue

    PROFILE_BN=$(basename "$PROFILE")
    INSTANCE_PART=$(echo "$PROFILE_BN" | awk -F'_' '{print $2}')
    if [[ -z "$INSTANCE_PART" || "$INSTANCE_PART" == "$PROFILE_BN" ]]; then
        # fallback: find token containing two trailing digits
        INSTANCE_PART=$(echo "$PROFILE_BN" | grep -oE '[A-Za-z0-9]+[0-9]{2}' | head -n1 || true)
        [[ -z "$INSTANCE_PART" ]] && INSTANCE_PART="$PROFILE_BN"
    fi

    # parse type and nr
    if [[ "$INSTANCE_PART" =~ ^(.+?)([0-9]{2})$ ]]; then
        INSTANCE_TYPE="${BASH_REMATCH[1]}"
        INSTANCE_NUMBER="${BASH_REMATCH[2]}"
    else
        INSTANCE_TYPE="$INSTANCE_PART"
        INSTANCE_NUMBER="NA"
    fi

    INSTANCE_PATH="/usr/sap/$SID/${INSTANCE_TYPE}${INSTANCE_NUMBER}"
    SID_LOWER=$(echo "$SID" | tr 'A-Z' 'a-z')

    RUNNING="No"
    ROLE="N/A"
    OWNER="-"

    dbg "Processing SID=$SID PART=$INSTANCE_PART TYPE=$INSTANCE_TYPE NR=$INSTANCE_NUMBER PATH=$INSTANCE_PATH"

    # ----------------- get sapcontrol STATE (prefer sidadm) -----------------
    STATE=""
    if [[ "$INSTANCE_NUMBER" != "NA" ]]; then
        STATE=$(run_sapcontrol_as_sidadm "$SID" "$INSTANCE_NUMBER" || true)
        dbg "sapcontrol output size: $(printf '%s' "$STATE" | wc -c)"
    fi

    # fallback to instance-local sapcontrol
    if [[ -z "$STATE" && -x "${INSTANCE_PATH}/exe/sapcontrol" ]]; then
        dbg "Trying instance-local sapcontrol at ${INSTANCE_PATH}/exe/sapcontrol"
        STATE=$(safe_run "${INSTANCE_PATH}/exe/sapcontrol" -nr "$INSTANCE_NUMBER" -function GetProcessList)
    fi

    # Interpret STATE
    if [[ -n "$STATE" ]]; then
        if printf "%s" "$STATE" | grep -q "GREEN"; then
            RUNNING="Yes"
        elif printf "%s" "$STATE" | grep -q "YELLOW"; then
            RUNNING="Degraded"
        fi
    fi

    # If no sapcontrol info, fall back to process checks
    if [[ "$RUNNING" != "Yes" && "$RUNNING" != "Degraded" ]]; then
        if pgrep -f "${INSTANCE_PART}" >/dev/null 2>&1 || pgrep -f "${INSTANCE_TYPE}${INSTANCE_NUMBER}" >/dev/null 2>&1 || pgrep -f "sapstartsrv.*${INSTANCE_PART}" >/dev/null 2>&1; then
            RUNNING="Yes"
        fi
    fi

    # ----------------- HANA: use SAPHanaSR-showAttr if present -----------------
    if [[ "${INSTANCE_TYPE^^}" == "HDB" || "${INSTANCE_PART^^}" =~ ^HDB[0-9]{2}$ ]]; then
        ROLE="No SR"
        # prefer SAPHanaSR-showAttr
        if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
            dbg "Using SAPHanaSR-showAttr for HANA SR role detection"
            HANASR=$(SAPHanaSR-showAttr 2>/dev/null || true)
            # find line where first column equals this host (case-insensitive)
            CLONE_STATE=$(printf "%s\n" "$HANASR" | awk -v host="$HOSTNAME" 'tolower($1)==tolower(host){print $2; exit}')
            dbg "SAPHanaSR-showAttr clone_state for $HOSTNAME: $CLONE_STATE"
            case "$CLONE_STATE" in
                PROMOTED) ROLE="PRIMARY" ;;
                DEMOTED)  ROLE="SECONDARY" ;;
                *)        ROLE="No SR" ;;
            esac
        else
            # fallback to sapcontrol GetSystemReplicationInfo if available
            if [[ -n "$STATE" ]]; then
                SRINFO=$(printf "%s\n" "$STATE")
            elif [[ -x "${INSTANCE_PATH}/exe/sapcontrol" ]]; then
                SRINFO=$(safe_run "${INSTANCE_PATH}/exe/sapcontrol" -nr "$INSTANCE_NUMBER" -function GetSystemReplicationInfo)
            else
                SRINFO=""
            fi
            if printf "%s" "$SRINFO" | grep -qi "PRIMARY"; then
                ROLE="PRIMARY"
            elif printf "%s" "$SRINFO" | grep -qi "SECONDARY"; then
                ROLE="SECONDARY"
            else
                ROLE="No SR"
            fi
        fi

        # Owner behavior per your chosen Option B: owner = local host for HANA rows
        if [[ $SHOW_OWNER -eq 1 ]]; then
            OWNER="$HOSTNAME"
        fi
    fi

    # ----------------- ASCS / ERS label and owner from crm_mon -----------------
    if [[ "${INSTANCE_PART^^}" =~ ^ASCS[0-9]{2}$ ]]; then
        ROLE="ASCS"
        if [[ $SHOW_OWNER -eq 1 ]]; then
            key="${SID}_${INSTANCE_TYPE}${INSTANCE_NUMBER}"
            OWNER="${RESOURCE_OWNER[$key]:--}"
        fi
    elif [[ "${INSTANCE_PART^^}" =~ ^ERS[0-9]{2}$ ]]; then
        ROLE="ERS"
        if [[ $SHOW_OWNER -eq 1 ]]; then
            key="${SID}_${INSTANCE_TYPE}${INSTANCE_NUMBER}"
            OWNER="${RESOURCE_OWNER[$key]:--}"
        fi
    fi

    # ----------------- App servers (Dnn) active/passive -----------------
    if [[ "$INSTANCE_PART" =~ ^D[0-9]{2}$ ]]; then
        if [[ -n "$STATE" ]]; then
            DISP_GREEN=$(printf "%s" "$STATE" | grep -i dispatcher | grep -c GREEN || true)
            DIA_GREEN=$( printf "%s" "$STATE" | grep -i DIA        | grep -c GREEN || true)
            if [[ $DISP_GREEN -gt 0 && $DIA_GREEN -gt 0 ]]; then
                ROLE="Active"
            elif [[ $DISP_GREEN -gt 0 && $DIA_GREEN -eq 0 ]]; then
                ROLE="Passive"
            else
                ROLE="Down"
            fi
        else
            ROLE=$([[ "$RUNNING" == "Yes" ]] && echo "Running" || echo "N/A")
        fi
    fi

    # ----------------- SMDA/DAA agents -----------------
    if [[ "${INSTANCE_TYPE^^}" == SMDA* || "${INSTANCE_PART^^}" =~ ^SMDA ]]; then
        ROLE="N/A"
        if pgrep -f "${INSTANCE_PART}" >/dev/null 2>&1 || pgrep -f "sapstartsrv.*${INSTANCE_PART}" >/dev/null 2>&1; then
            RUNNING="Yes"
        fi
        if [[ $SHOW_OWNER -eq 1 && -z "$OWNER" ]]; then
            OWNER="-"
        fi
    fi

    # Ensure OWNER default when --owner requested
    if [[ $SHOW_OWNER -eq 1 && -z "$OWNER" ]]; then
        OWNER="-"
    fi

    # ----------------- Print row -----------------
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-6s %-4s %-12s %-10s %-12s %-20s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "${INSTANCE_PART}" "$RUNNING" "$ROLE" "$OWNER"
    else
        printf "%-20s %-6s %-4s %-12s %-10s %-12s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "${INSTANCE_PART}" "$RUNNING" "$ROLE"
    fi

done < "$SAPSERVICES"

exit 0
