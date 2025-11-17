#!/usr/bin/env bash
# sap_status_clustered_v12.sh
# Cluster-aware SAP instance status (v12)
# - SLES-friendly, HANA SR simple roles (PRIMARY / SECONDARY / No SR)
# - Optional --owner column (ASCS/ERS from crm_mon; HANA owner = local host)
# - Optional --debug for diagnostics
set -euo pipefail

# -------------------------
# CLI parsing (robust)
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

dbg() { $DEBUG && printf "DEBUG: %s\n" "$*" >&2; }

HOSTNAME=$(hostname -s)
SAPSERVICES="/usr/sap/sapservices"

# Ensure sapservices exists
if [[ ! -f "$SAPSERVICES" ]]; then
    echo "No $SAPSERVICES found" >&2
    exit 0
fi

# -------------------------
# Collect CRM owners if requested
# -------------------------
declare -A RESOURCE_OWNER
SAPHANA_SR_FULL=""

if [[ $SHOW_OWNER -eq 1 ]]; then
    if command -v crm_mon >/dev/null 2>&1; then
        dbg "Collecting crm_mon output"
        CRM_OUT=$(crm_mon -1 -r 2>/dev/null || true)

        # parse rsc_sap_* Started <node>
        while IFS= read -r ln; do
            if [[ "$ln" =~ rsc_sap_([A-Za-z0-9_]+)[^:]*:[[:space:]]*Started[[:space:]]+([A-Za-z0-9._-]+) ]]; then
                key="${BASH_REMATCH[1]}"     # e.g. D3G_ASCS00
                owner="${BASH_REMATCH[2]}"
                RESOURCE_OWNER["$key"]="$owner"
                dbg "RESOURCE_OWNER[$key]=$owner"
            fi
        done <<< "$CRM_OUT"

        # If SAPHanaSR-showAttr is available, capture full output for parsing
        if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
            SAPHANA_SR_FULL=$(SAPHanaSR-showAttr 2>/dev/null || true)
            dbg "Captured SAPHanaSR-showAttr output"
        fi
    else
        dbg "crm_mon not found; owner resolution will be limited"
        # still try to capture SAPHanaSR-showAttr if available
        if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
            SAPHANA_SR_FULL=$(SAPHanaSR-showAttr 2>/dev/null || true)
            dbg "Captured SAPHanaSR-showAttr output"
        fi
    fi
else
    # still capture SAPHanaSR-showAttr if present for role detection
    if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
        SAPHANA_SR_FULL=$(SAPHanaSR-showAttr 2>/dev/null || true)
        dbg "Captured SAPHanaSR-showAttr output"
    fi
fi

# -------------------------
# Helpers
# -------------------------

# Run a full-path sapcontrol as sidadm (SLES). Returns stdout or empty.
run_sapcontrol_fullpath_as_sidadm() {
    local sid="$1"      # SID uppercase
    local inst_dir="$2" # e.g. HDB00, ASCS00
    local nr="$3"       # e.g. 00
    local sc_path="/usr/sap/${sid}/${inst_dir}/exe/sapcontrol"

    if [[ -x "$sc_path" ]]; then
        local sidadm
        sidadm="$(echo "$sid" | tr '[:upper:]' '[:lower:]')adm"
        if command -v sudo >/dev/null 2>&1; then
            dbg "Using sudo -u $sidadm $sc_path -nr $nr -function GetProcessList"
            sudo -u "$sidadm" "$sc_path" -nr "$nr" -function GetProcessList 2>/dev/null || true
        else
            dbg "sudo not found, using su - $sidadm -c ..."
            su - "$sidadm" -c "$sc_path -nr $nr -function GetProcessList" 2>/dev/null || true
        fi
    else
        dbg "sapcontrol not executable at $sc_path"
        echo ""
    fi
}

# Run sapcontrol GetSystemReplicationInfo as sidadm (fallback)
run_sapcontrol_srinfo_as_sidadm() {
    local sid="$1"
    local inst_dir="$2"
    local nr="$3"
    local sc_path="/usr/sap/${sid}/${inst_dir}/exe/sapcontrol"

    if [[ -x "$sc_path" ]]; then
        local sidadm
        sidadm="$(echo "$sid" | tr '[:upper:]' '[:lower:]')adm"
        if command -v sudo >/dev/null 2>&1; then
            sudo -u "$sidadm" "$sc_path" -nr "$nr" -function GetSystemReplicationInfo 2>/dev/null || true
        else
            su - "$sidadm" -c "$sc_path -nr $nr -function GetSystemReplicationInfo" 2>/dev/null || true
        fi
    else
        echo ""
    fi
}

# Parse SAPHanaSR-showAttr cached output for a host -> set globals CLONE_STATE and SRMODE
parse_saphanasr_for_host() {
    local host="$1"
    CLONE_STATE=""
    SRMODE=""
    if [[ -z "${SAPHANA_SR_FULL:-}" ]]; then
        return 0
    fi
    # find line starting with hostname (case-insensitive)
    local line
    line=$(printf "%s\n" "$SAPHANA_SR_FULL" | awk -v h="$host" 'tolower($1)==tolower(h){print; exit}')
    if [[ -n "$line" ]]; then
        CLONE_STATE=$(printf "%s\n" "$line" | awk '{print toupper($2)}' 2>/dev/null || true)
        # srmode token example: PRIM / SOK / SFAIL (search for those)
        SRMODE=$(printf "%s\n" "$line" | grep -oE -i '\b(PRIM|SOK|SFAIL|SYNC|OFF)\b' | head -n1 | tr '[:lower:]' '[:upper:]' || true)
        dbg "parse_saphanasr_for_host: host=$host clone_state=$CLONE_STATE srmode=$SRMODE"
    fi
}

# Format HANA role per Option A: PRIMARY / SECONDARY / No SR
format_hana_role_simple() {
    local clone_state="$1"
    clone_state=$(printf "%s" "$clone_state" | tr '[:lower:]' '[:upper:]')
    if [[ "$clone_state" == "PROMOTED" ]]; then
        printf "PRIMARY"
    elif [[ "$clone_state" == "DEMOTED" ]]; then
        printf "SECONDARY"
    else
        printf "No SR"
    fi
}

# get resource owner for ASCS/ERS from map (key like D3G_ASCS00)
get_map_owner() {
    local key="$1"
    printf "%s" "${RESOURCE_OWNER[$key]:-}"
}

# sanitize single-line value (remove newlines & compress spaces)
sanitize_single_line() {
    local val="$1"
    printf "%s" "$val" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

# -------------------------
# Header
# -------------------------
if [[ $SHOW_OWNER -eq 1 ]]; then
    printf "%-20s %-6s %-4s %-12s %-10s %-12s %-20s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-20s %-6s %-4s %-12s %-10s %-12s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

# -------------------------
# Iterate sapservices
# -------------------------
while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *"/usr/sap/"* ]] && continue

    PROFILE=$(echo "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p' || true)
    [[ -z "$PROFILE" ]] && continue
    PROFILE="${PROFILE%\"}"
    PROFILE="${PROFILE#\"}"
    PROFILE="${PROFILE%\'}"
    PROFILE="${PROFILE#\'}"

    SID=$(echo "$PROFILE" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="sap"){print $(i+1); exit}}')
    [[ -z "$SID" ]] && continue

    PROFILE_BN=$(basename "$PROFILE")
    INSTANCE_PART=$(echo "$PROFILE_BN" | awk -F'_' '{print $2}')
    if [[ -z "$INSTANCE_PART" || "$INSTANCE_PART" == "$PROFILE_BN" ]]; then
        INSTANCE_PART=$(echo "$PROFILE_BN" | grep -oE '[A-Za-z0-9]+[0-9]{2}' | head -n1 || true)
        [[ -z "$INSTANCE_PART" ]] && INSTANCE_PART="$PROFILE_BN"
    fi

    if [[ "$INSTANCE_PART" =~ ^(.+?)([0-9]{2})$ ]]; then
        INSTANCE_TYPE="${BASH_REMATCH[1]}"
        INSTANCE_NUMBER="${BASH_REMATCH[2]}"
    else
        INSTANCE_TYPE="$INSTANCE_PART"
        INSTANCE_NUMBER="NA"
    fi

    INST_DIR="${INSTANCE_TYPE}${INSTANCE_NUMBER}"

    dbg "Parsed instance: SID=$SID INST_DIR=$INST_DIR TYPE=$INSTANCE_TYPE NR=$INSTANCE_NUMBER"

    # --- detect running state using full path as sidadm for HANA, else try local or PATH sapcontrol
    RUNNING="No"
    STATE_OUT=""

    # attempt run as sidadm via fullpath
    STATE_OUT=$(run_sapcontrol_fullpath_as_sidadm "$SID" "$INST_DIR" "$INSTANCE_NUMBER" || true)

    # fallback: try instance-local sapcontrol (no sudo) if above empty
    if [[ -z "$STATE_OUT" ]]; then
        SC_LOCAL="/usr/sap/$SID/$INST_DIR/exe/sapcontrol"
        if [[ -x "$SC_LOCAL" ]]; then
            dbg "Trying local sapcontrol at $SC_LOCAL"
            STATE_OUT=$("$SC_LOCAL" -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
        fi
    fi

    # final fallback: try sapcontrol from PATH (rare)
    if [[ -z "$STATE_OUT" && -x "$(command -v sapcontrol 2>/dev/null || true)" ]]; then
        dbg "Trying sapcontrol in PATH"
        STATE_OUT=$(sapcontrol -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
    fi

    # If any GREEN present (case-insensitive), consider running
    if [[ -n "$STATE_OUT" ]] && printf "%s" "$STATE_OUT" | grep -qi "GREEN"; then
        RUNNING="Yes"
    fi

    # --- HANA SR role (Option A mapping)
    ROLE_OUT="N/A"
    OWNER_OUT="$HOSTNAME"

    if [[ "${INSTANCE_TYPE^^}" == "HDB" || "${INSTANCE_PART^^}" =~ ^HDB[0-9]{2}$ ]]; then
        # parse SAPHanaSR-showAttr cached output for this host
        parse_saphanasr_for_host "$HOSTNAME"
        ROLE_OUT=$(format_hana_role_simple "${CLONE_STATE:-}")
        # fallback: use sapcontrol GetSystemReplicationInfo if no SAPHanaSR details
        if [[ "$ROLE_OUT" == "No SR" ]]; then
            SRINFO=$(run_sapcontrol_srinfo_as_sidadm "$SID" "$INST_DIR" "$INSTANCE_NUMBER" || true)
            if [[ -n "$SRINFO" ]]; then
                if printf "%s" "$SRINFO" | grep -qi "PRIMARY"; then
                    ROLE_OUT="PRIMARY"
                elif printf "%s" "$SRINFO" | grep -qi "SECONDARY"; then
                    ROLE_OUT="SECONDARY"
                fi
            fi
        fi
        # Per Option B earlier: HANA owner column shows local host (owner = host)
        OWNER_OUT="$HOSTNAME"
    else
        # ASCS/ERS mapping
        if [[ "${INSTANCE_PART^^}" =~ ^ASCS[0-9]{2}$ ]]; then
            ROLE_OUT="ASCS"
            if [[ $SHOW_OWNER -eq 1 ]]; then
                key="${SID}_${INST_DIR}"
                owner_v=$(get_map_owner "$key")
                OWNER_OUT="${owner_v:-$HOSTNAME}"
            fi
        elif [[ "${INSTANCE_PART^^}" =~ ^ERS[0-9]{2}$ ]]; then
            ROLE_OUT="ERS"
            if [[ $SHOW_OWNER -eq 1 ]]; then
                key="${SID}_${INST_DIR}"
                owner_v=$(get_map_owner "$key")
                OWNER_OUT="${owner_v:-$HOSTNAME}"
            fi
        else
            ROLE_OUT="N/A"
            OWNER_OUT="$HOSTNAME"
        fi
    fi

    # sanitize multi-line values (collapse newlines & trim)
    ROLE_CLEAN=$(sanitize_single_line "$ROLE_OUT")
    OWNER_CLEAN=$(sanitize_single_line "$OWNER_OUT")

    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-6s %-4s %-12s %-10s %-12s %-20s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INST_DIR" "$RUNNING" "$ROLE_CLEAN" "$OWNER_CLEAN"
    else
        printf "%-20s %-6s %-4s %-12s %-10s %-12s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INST_DIR" "$RUNNING" "$ROLE_CLEAN"
    fi

done < "$SAPSERVICES"

exit 0
