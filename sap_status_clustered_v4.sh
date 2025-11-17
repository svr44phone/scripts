 #!/bin/bash
#
# SAP Instance Status Report (Cluster-Aware)
# v4 — with optional --owner column (Pacemaker resource owner)
#
# Supports:
#   * HANA (Primary/Secondary detection)
#   * NetWeaver ENSA2 ASCS/ERS
#   * PAS/AAS dispatcher/DIA check
#   * SMDA/DAA
#   * Pacemaker resource owner resolution
#
# Usage:
#   ./sap_status_clustered_v4.sh
#   ./sap_status_clustered_v4.sh --owner     # adds Owner column
#

set -euo pipefail

SHOW_OWNER=0
[[ "${1:-}" == "--owner" ]] && SHOW_OWNER=1

HOSTNAME=$(hostname)
SAPSERVICES="/usr/sap/sapservices"

# ------------------------------------------------------------------------------
# Collect cluster ownership information if requested
# ------------------------------------------------------------------------------
declare -A RESOURCE_OWNER

if [[ $SHOW_OWNER -eq 1 ]]; then
    if command -v crm_mon >/dev/null 2>&1; then
        CRM_OUT=$(crm_mon -1 -r 2>/dev/null || true)

        # Example lines:
        #   rsc_sap_D3G_ASCS00 (ocf...): Started azlsapd3ger01
        #   rsc_sap_D3G_ERS01 (ocf...): Started azlsapd3gcs01
        #
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*\*?[[:space:]]*rsc_sap_([A-Za-z0-9_]+)[[:space:]]*\(.*\):[[:space:]]*Started[[:space:]]+([A-Za-z0-9._-]+) ]]; then
                RES="${BASH_REMATCH[1]}"
                OWNER="${BASH_REMATCH[2]}"
                RESOURCE_OWNER["$RES"]="$OWNER"
            fi
        done <<< "$CRM_OUT"
    fi
fi

# ------------------------------------------------------------------------------
# Output header
# ------------------------------------------------------------------------------
if [[ $SHOW_OWNER -eq 1 ]]; then
    printf "%-20s %-5s %-4s %-10s %-10s %-12s %-20s\n" \
        "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-20s %-5s %-4s %-10s %-10s %-12s\n" \
        "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

# ------------------------------------------------------------------------------
# Utility safe wrapper
# ------------------------------------------------------------------------------
safe_run() {
    "$@" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Main Loop — parse sapservices
# ------------------------------------------------------------------------------
if [[ ! -f "$SAPSERVICES" ]]; then
    echo "No /usr/sap/sapservices found"
    exit 0
fi

grep -v '^#' "$SAPSERVICES" | grep "/usr/sap/" | while read -r line; do

    PROFILE=$(echo "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p')
    [[ -z "$PROFILE" ]] && continue

    SID=$(echo "$PROFILE" | awk -F'/' '{print $4}')
    INSTANCE_PART=$(basename "$PROFILE" | awk -F'_' '{print $2}')

    # Parse TYPE + NR (e.g. ASCS00, ERS01, D00, SMDA97)
    if [[ "$INSTANCE_PART" =~ ^(.+)([0-9]{2})$ ]]; then
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
    OWNER_NODE=""

    # ------------------------------------------------------------------------------
    # Try sapcontrol first using SID adm (works on clusters even if instance dir not mounted)
    # ------------------------------------------------------------------------------
    STATE=""
    if id "${SID_LOWER}adm" >/dev/null 2>&1; then
        STATE=$(safe_run su - "${SID_LOWER}adm" -c "sapcontrol -nr ${INSTANCE_NUMBER} -function GetProcessList")
    fi

    if echo "$STATE" | grep -q "GREEN"; then
        RUNNING="Yes"
    elif echo "$STATE" | grep -q "YELLOW"; then
        RUNNING="Degraded"
    fi

    # ------------------------------------------------------------------------------
    # HANA SR role detection
    # ------------------------------------------------------------------------------
    if [[ "$INSTANCE_TYPE" == "HDB" ]]; then
        if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
            HANASR=$(safe_run SAPHanaSR-showAttr | grep -E "^$HOSTNAME[[:space:]]")
            CLONE_STATE=$(echo "$HANASR" | awk '{print $2}')
            case "$CLONE_STATE" in
                PROMOTED) ROLE="Primary" ;;
                DEMOTED)  ROLE="Secondary" ;;
                *)        ROLE="No SR" ;;
            esac
        fi
    fi

    # ------------------------------------------------------------------------------
    # ENSA2 role labeling
    # ------------------------------------------------------------------------------
    case "$INSTANCE_TYPE" in
        ASCS*) ROLE="ASCS" ;;
        ERS*)  ROLE="ERS" ;;
    esac

    # ------------------------------------------------------------------------------
    # Application Server Role
    # ------------------------------------------------------------------------------
    if [[ "$INSTANCE_PART" =~ ^D[0-9]{2}$ ]]; then
        DISP_GREEN=$(echo "$STATE" | grep -i dispatcher | grep -c GREEN)
        DIA_GREEN=$( echo "$STATE" | grep -i DIA        | grep -c GREEN)

        if [[ $DISP_GREEN -gt 0 && $DIA_GREEN -gt 0 ]]; then
            ROLE="Active"
        elif [[ $DISP_GREEN -gt 0 && $DIA_GREEN -eq 0 ]]; then
            ROLE="Passive"
        else
            ROLE="Down"
        fi
    fi

    # ------------------------------------------------------------------------------
    # Cluster owner resolution (only if --owner)
    # ------------------------------------------------------------------------------
    if [[ $SHOW_OWNER -eq 1 ]]; then
        # SAPInstance resources are named rsc_sap_<SID>_<TYPE><NR>
        RESKEY="${SID}_${INSTANCE_TYPE}${INSTANCE_NUMBER}"

        OWNER_NODE="${RESOURCE_OWNER[$RESKEY]:-}"
        [[ -z "$OWNER_NODE" ]] && OWNER_NODE="-"
    fi

    # ------------------------------------------------------------------------------
    # Output row
    # ------------------------------------------------------------------------------
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-5s %-4s %-10s %-10s %-12s %-20s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" \
            "${INSTANCE_TYPE}${INSTANCE_NUMBER}" \
            "$RUNNING" "$ROLE" "$OWNER_NODE"
    else
        printf "%-20s %-5s %-4s %-10s %-10s %-12s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" \
            "${INSTANCE_TYPE}${INSTANCE_NUMBER}" \
            "$RUNNING" "$ROLE"
    fi

done
