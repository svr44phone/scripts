#!/usr/bin/env bash
#
# sap_status_clustered_v11.sh
# Cluster-aware SAP status (v11)
# - SLES 15 friendly
# - Uses full sapcontrol paths invoked as the sidadm user
# - HANA SR parsing via SAPHanaSR-showAttr (role format: PRIMARY (PRIM) / SECONDARY (SOK))
# - Optional --owner column (Pacemaker owner resolution for ASCS/ERS/HANA VIP)
# - Optional --debug for troubleshooting (prints to stderr)
#
set -euo pipefail

SHOW_OWNER=0
DEBUG=0

for a in "$@"; do
    case "$a" in
        --owner) SHOW_OWNER=1 ;;
        --debug) DEBUG=1 ;;
        *) ;;
    esac
done

dbg() { $DEBUG && printf "DEBUG: %s\n" "$*" >&2; }

HOSTNAME=$(hostname -s)
SAPSERVICES="/usr/sap/sapservices"

if [[ ! -f "$SAPSERVICES" ]]; then
    echo "No $SAPSERVICES found" >&2
    exit 0
fi

# -------------------------------------------------------------------
# Build map of pacemaker resource owners (if requested)
# -------------------------------------------------------------------
declare -A RESOURCE_OWNER

if [[ $SHOW_OWNER -eq 1 ]] && command -v crm_mon >/dev/null 2>&1; then
    dbg "Collecting crm_mon output for owner mapping"
    CRM_OUT=$(crm_mon -1 -r 2>/dev/null || true)
    # find lines like: rsc_sap_D3G_ASCS00 (ocf::...):    Started azlsapd3ger01
    while IFS= read -r ln; do
        if [[ "$ln" =~ rsc_sap_([A-Za-z0-9_]+)[^:]*:[[:space:]]*Started[[:space:]]+([A-Za-z0-9._-]+) ]]; then
            key="${BASH_REMATCH[1]}"      # e.g. D3G_ASCS00
            owner="${BASH_REMATCH[2]}"    # e.g. azlsapd3ger01
            RESOURCE_OWNER["$key"]="$owner"
            dbg "Resource owner: $key -> $owner"
        fi
    done <<< "$CRM_OUT"
    # capture HANA clone master info (masters/slaves)
    # We'll also keep the full SAPHanaSR-showAttr output if present
    if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
        SAPHANA_SR_FULL=$(SAPHanaSR-showAttr 2>/dev/null || true)
        dbg "Collected SAPHanaSR-showAttr"
    else
        SAPHANA_SR_FULL=""
    fi
else
    SAPHANA_SR_FULL=""
fi

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

# Run sapcontrol via full path as sidadm (SLES). Returns stdout or empty.
run_sapcontrol_fullpath_as_sidadm() {
    local sid="$1"      # SID uppercase
    local inst_dir="$2" # e.g. HDB00 or ASCS00
    local nr="$3"       # instance nr, two digits
    local sc_path="/usr/sap/${sid}/${inst_dir}/exe/sapcontrol"

    if [[ -x "$sc_path" ]]; then
        # run as sidadm using sudo -u <sid>adm and full path (SLES)
        local sidadm="$(echo "$sid" | tr 'A-Z' 'a-z')adm"
        dbg "Running sapcontrol: sudo -u $sidadm $sc_path -nr $nr -function"
        sudo -u "$sidadm" "$sc_path" -nr "$nr" -function GetProcessList 2>/dev/null || true
    else
        dbg "sapcontrol not found at $sc_path"
        echo ""
    fi
}

# Run sapcontrol GetSystemReplicationInfo (fullpath) as sidadm (for HANA fallback)
run_sapcontrol_srinfo_as_sidadm() {
    local sid="$1"
    local inst_dir="$2"
    local nr="$3"
    local sc_path="/usr/sap/${sid}/${inst_dir}/exe/sapcontrol"

    if [[ -x "$sc_path" ]]; then
        local sidadm="$(echo "$sid" | tr 'A-Z' 'a-z')adm"
        sudo -u "$sidadm" "$sc_path" -nr "$nr" -function GetSystemReplicationInfo 2>/dev/null || true
    else
        echo ""
    fi
}

# Parse SAPHanaSR-showAttr line for a host and return clone_state, srmode, site
# returns via globals PARSE_CLONE_STATE, PARSE_SRMODE, PARSE_SITE
parse_saphanasr_for_host() {
    local host="$1"
    PARSE_CLONE_STATE=""
    PARSE_SRMODE=""
    PARSE_SITE=""

    if [[ -z "${SAPHANA_SR_FULL:-}" ]]; then
        # try to get it on-demand
        if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
            SAPHANA_SR_FULL=$(SAPHanaSR-showAttr 2>/dev/null || true)
        fi
    fi

    if [[ -n "${SAPHANA_SR_FULL:-}" ]]; then
        # find line starting with hostname (case-insensitive)
        local line
        line=$(printf "%s\n" "$SAPHANA_SR_FULL" | awk -v h="$host" 'tolower($1)==tolower(h){print; exit}')
        if [[ -n "$line" ]]; then
            # clone_state is 2nd column in examples
            PARSE_CLONE_STATE=$(printf "%s\n" "$line" | awk '{print toupper($2)}')
            # srmode appears as e.g. PRIM / SOK / SFAIL / sync etc. Try to find common tokens
            PARSE_SRMODE=$(printf "%s\n" "$line" | grep -oE -i '\b(PRIM|SOK|SFAIL|SYNC|OFF|SYNCON|PRIM1|PRIM2)\b' | head -n1 | tr '[:lower:]' '[:upper:]' || true)
            # site codes like D3GP / D3GS often appear; extract pattern D<digit><2letters>
            PARSE_SITE=$(printf "%s\n" "$line" | grep -oE -i '\bD[0-9][A-Z]{2}\b' | head -n1 | tr '[:lower:]' '[:upper:]' || true)
            dbg "parse_saphanasr_for_host: host=$host clone_state=$PARSE_CLONE_STATE srmode=$PARSE_SRMODE site=$PARSE_SITE"
        fi
    fi
}

# Map clone_state + srmode to display role (we include srmode in parentheses per your choice)
format_hana_role() {
    local clone_state="$1"
    local srmode="$2"

    # normalize
    clone_state=$(echo "$clone_state" | tr '[:lower:]' '[:upper:]')
    srmode=$(echo "$srmode" | tr '[:lower:]' '[:upper:]')

    local role_word="No SR"
    if [[ "$clone_state" == "PROMOTED" ]]; then
        role_word="PRIMARY"
    elif [[ "$clone_state" == "DEMOTED" ]]; then
        role_word="SECONDARY"
    fi

    if [[ -n "$srmode" ]]; then
        printf "%s (%s)" "$role_word" "$srmode"
    else
        printf "%s" "$role_word"
    fi
}

# Get owner for ASCS/ERS resource key SID_ASCS00 or SID_ERS01
get_resource_owner_from_map() {
    local key="$1"
    printf "%s" "${RESOURCE_OWNER[$key]:-}"
}

# -------------------------------------------------------------------
# Header
# -------------------------------------------------------------------
if [[ $SHOW_OWNER -eq 1 ]]; then
    printf "%-20s %-6s %-4s %-12s %-10s %-20s %-20s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-20s %-6s %-4s %-12s %-10s %-20s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

# -------------------------------------------------------------------
# Main: parse sapservices lines (avoid subshell)
# -------------------------------------------------------------------
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

    INST_DIR="${INSTANCE_TYPE}${INSTANCE_NUMBER}"   # directory name, usually matches filesystem

    dbg "Instance parsed: SID=$SID PART=$INSTANCE_PART TYPE=$INSTANCE_TYPE NR=$INSTANCE_NUMBER DIR=$INST_DIR"

    # -------------------- sapcontrol / running detection --------------------
    RUNNING="No"
    STATE_OUT=""

    # Use full sapcontrol path executed as sidadm (SLES)
    STATE_OUT=$(run_sapcontrol_fullpath_as_sidadm "$SID" "$INST_DIR" "$INSTANCE_NUMBER" || true)

    # If we didn't get output, try instance-local sapcontrol without sudo (rare)
    if [[ -z "$STATE_OUT" ]]; then
        SC_LOCAL="/usr/sap/$SID/$INST_DIR/exe/sapcontrol"
        if [[ -x "$SC_LOCAL" ]]; then
            STATE_OUT=$("$SC_LOCAL" -nr "$INSTANCE_NUMBER" -function GetProcessList 2>/dev/null || true)
        fi
    fi

    # If STATE_OUT contains any GREEN (case-insensitive), consider running
    if [[ -n "$STATE_OUT" ]] && printf "%s" "$STATE_OUT" | grep -q -i "GREEN"; then
        RUNNING="Yes"
    fi

    # -------------------- HANA SR/Role detection --------------------
    ROLE_DISPLAY="N/A"
    if [[ "${INSTANCE_TYPE^^}" == "HDB" || "${INSTANCE_PART^^}" =~ ^HDB[0-9]{2}$ ]]; then
        # parse SAPHanaSR-showAttr for this host
        parse_saphanasr_for_host "$HOSTNAME"
        # PARSE_CLONE_STATE, PARSE_SRMODE, PARSE_SITE now available (may be empty)
        ROLE_DISPLAY=$(format_hana_role "${PARSE_CLONE_STATE:-}" "${PARSE_SRMODE:-}")
        # If SAPHanaSR didn't return anything, fallback to sapcontrol GetSystemReplicationInfo if available
        if [[ "$ROLE_DISPLAY" == "No SR" ]]; then
            SRINFO=$(run_sapcontrol_srinfo_as_sidadm "$SID" "$INST_DIR" "$INSTANCE_NUMBER" || true)
            if [[ -n "$SRINFO" ]]; then
                if printf "%s" "$SRINFO" | grep -qi "PRIMARY"; then
                    ROLE_DISPLAY="PRIMARY"
                elif printf "%s" "$SRINFO" | grep -qi "SECONDARY"; then
                    ROLE_DISPLAY="SECONDARY"
                fi
            fi
        fi
        # If user asked for owner, Option B: owner = local host for HANA rows
        OWNER_DISPLAY="$HOSTNAME"
    else
        # ASCS/ERS labeling
        if [[ "${INSTANCE_PART^^}" =~ ^ASCS[0-9]{2}$ ]]; then
            ROLE_DISPLAY="ASCS"
            # owner via resource map if requested
            if [[ $SHOW_OWNER -eq 1 ]]; then
                key="${SID}_${INST_DIR}"
                owner_v=$(get_resource_owner_from_map "$key")
                OWNER_DISPLAY="${owner_v:-$HOSTNAME}"
            fi
        elif [[ "${INSTANCE_PART^^}" =~ ^ERS[0-9]{2}$ ]]; then
            ROLE_DISPLAY="ERS"
            if [[ $SHOW_OWNER -eq 1 ]]; then
                key="${SID}_${INST_DIR}"
                owner_v=$(get_resource_owner_from_map "$key")
                OWNER_DISPLAY="${owner_v:-$HOSTNAME}"
            fi
        else
            ROLE_DISPLAY="N/A"
            OWNER_DISPLAY="$HOSTNAME"
        fi
    fi

    # ----------------------------------------------------------------
    # ensure single-line outputs (trim newlines from ROLE_DISPLAY, OWNER_DISPLAY)
    ROLE_CLEAN=$(printf "%s" "$ROLE_DISPLAY" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]//; s/[[:space:]]$//')
    OWNER_CLEAN=$(printf "%s" "${OWNER_DISPLAY:-$HOSTNAME}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]//; s/[[:space:]]$//')

    # ----------------------------------------------------------------
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-20s %-6s %-4s %-12s %-10s %-20s %-20s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INST_DIR" "$RUNNING" "$ROLE_CLEAN" "$OWNER_CLEAN"
    else
        printf "%-20s %-6s %-4s %-12s %-10s %-20s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INST_DIR" "$RUNNING" "$ROLE_CLEAN"
    fi

done < "$SAPSERVICES"

exit 0
