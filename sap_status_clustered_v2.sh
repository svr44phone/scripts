#!/usr/bin/env bash
# SAP Instance Status Report Script (cluster-aware, robust)
# Usage: ./sap_status_clustered_v2.sh [--json]
set -euo pipefail

OUTPUT_JSON=false
if [[ "${1:-}" == "--json" ]]; then
    OUTPUT_JSON=true
fi

HOSTNAME=$(hostname)
SAPSRV="/usr/sap/sapservices"

if [[ ! -f "$SAPSRV" ]]; then
    echo "No $SAPSRV found" >&2
    exit 0
fi

# Helpers
safe_run() {
    # run a command, return its stdout or empty string on failure (no error exit)
    local _out
    _out=$("$@" 2>/dev/null) || _out=""
    printf "%s" "$_out"
}

# Emit header or collect JSON
if ! $OUTPUT_JSON; then
    printf "%-20s %-5s %-4s %-10s %-10s %-12s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
else
    json_items=()
fi

# Read sapservices without using a pipeline (avoid subshell)
while IFS= read -r line; do
    # skip comments and empty lines and lines without /usr/sap/
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *"/usr/sap/"* ]] && continue

    # Extract pf= value (profile path)
    PROFILE=$(echo "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p' || true)
    [[ -z "$PROFILE" ]] && continue

    # If profile path is quoted, strip quotes
    PROFILE="${PROFILE%\"}"
    PROFILE="${PROFILE#\"}"
    PROFILE="${PROFILE%\'}"
    PROFILE="${PROFILE#\'}"

    # If profile file doesn't exist, still try to parse; but continue if path is clearly wrong
    # SID: directory after /usr/sap/
    # We look for the first path element after /usr/sap
    SID=$(echo "$PROFILE" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="sap"){print $(i+1); exit}}')
    [[ -z "$SID" ]] && continue

    # Get the instance token from profile filename staging: usually SID_<INSTPART>_HOST
    PROFILE_BN=$(basename "$PROFILE")
    # Guard: if basename doesn't have '_' segments, fallback to searching for pattern like *_<TYPE><NN>*
    INSTANCE_FIELD=$(echo "$PROFILE_BN" | awk -F'_' '{print $2}')
    if [[ -z "$INSTANCE_FIELD" || "$INSTANCE_FIELD" == "$PROFILE_BN" ]]; then
        # fallback: find segment with trailing two digits
        INSTANCE_FIELD=$(echo "$PROFILE_BN" | grep -oE '[A-Za-z0-9]+[0-9]{2}' | head -n1 || true)
        [[ -z "$INSTANCE_FIELD" ]] && INSTANCE_FIELD="$PROFILE_BN"
    fi
    INSTANCE_PART="$INSTANCE_FIELD"   # e.g. HDB00, D00, ASCS01, SMDA98, G10

    # Parse type/number
    if [[ "$INSTANCE_PART" =~ ^(.+?)([0-9]{2})$ ]]; then
        INSTANCE_TYPE="${BASH_REMATCH[1]}"  # e.g. HDB, D, ASCS, SMDA, G
        INSTANCE_NUMBER="${BASH_REMATCH[2]}" # e.g. 00, 10, 98
    else
        INSTANCE_TYPE="$INSTANCE_PART"
        INSTANCE_NUMBER="NA"
    fi

    # Construct instance path (best-effort)
    INSTANCE_PATH="/usr/sap/$SID/${INSTANCE_TYPE}${INSTANCE_NUMBER}"

    RUNNING="No"
    ROLE="N/A"
    STATE=""

    SAPCTL="$INSTANCE_PATH/exe/sapcontrol"

    # If sapcontrol exists and is executable, use it (except for SMDA where process check is easier)
    if [[ -x "$SAPCTL" ]]; then
        if [[ "$INSTANCE_TYPE" =~ ^SMDA ]]; then
            # Diagnostic Agent - check by process name
            if pgrep -f "${INSTANCE_TYPE}${INSTANCE_NUMBER}" >/dev/null 2>&1 || \
               pgrep -f "sapstartsrv.*${INSTANCE_TYPE}${INSTANCE_NUMBER}" >/dev/null 2>&1; then
                RUNNING="Yes"
            fi
        else
            # Get process list via sapcontrol; allow failure
            STATE=$(safe_run "$SAPCTL" -nr "$INSTANCE_NUMBER" -function GetProcessList)
            if echo "$STATE" | grep -q "GREEN"; then
                RUNNING="Yes"
            elif echo "$STATE" | grep -q "YELLOW"; then
                RUNNING="Degraded"
            fi

            # HANA SR Role detection
            if [[ "${INSTANCE_TYPE^^}" == "HDB" || "${INSTANCE_PART^^}" =~ ^HDB[0-9]{2}$ ]]; then
                # Prefer SAPHanaSR-showAttr if available
                if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
                    # Output lines like: hostname <state> ...
                    HANASR=$(safe_run SAPHanaSR-showAttr)
                    if [[ -n "$HANASR" ]]; then
                        # find line beginning with hostname
                        LINE=$(echo "$HANASR" | grep -E "^${HOSTNAME}[[:space:]]" || true)
                        if [[ -n "$LINE" ]]; then
                            SRFLAG=$(echo "$LINE" | awk '{print $2}')
                            case "$SRFLAG" in
                                PROMOTED) ROLE="Primary" ;;
                                DEMOTED)  ROLE="Secondary" ;;
                                *)        ROLE="No SR" ;;
                            esac
                        fi
                    fi
                else
                    # Try hdbnsutil somewhere under /usr/sap/<SID>
                    HDBNSUTIL_PATH=$(find "/usr/sap/$SID" -type f -name hdbnsutil 2>/dev/null | head -n1 || true)
                    if [[ -n "$HDBNSUTIL_PATH" ]]; then
                        # Run as <sid>adm if available
                        SID_LOWER=$(echo "$SID" | tr 'A-Z' 'a-z')
                        if id "${SID_LOWER}adm" >/dev/null 2>&1; then
                            SR_STATE=$(safe_run su - "${SID_LOWER}adm" -c "'$HDBNSUTIL_PATH' -sr_state" 2>/dev/null || true)
                        else
                            SR_STATE=$(safe_run "$HDBNSUTIL_PATH" -sr_state)
                        fi
                        if echo "$SR_STATE" | grep -qi "mode: primary"; then
                            ROLE="Primary"
                        elif echo "$SR_STATE" | grep -qi "mode: secondary"; then
                            ROLE="Secondary"
                        else
                            ROLE="No SR"
                        fi
                    fi
                fi
            fi

            # ASCS/ERS
            if [[ "${INSTANCE_TYPE^^}" == ASCS* ]]; then
                ROLE="ASCS"
            elif [[ "${INSTANCE_TYPE^^}" == ERS* ]]; then
                ROLE="ERS"
            fi

            # App servers detection (use INSTANCE_PART like D00)
            if [[ "$INSTANCE_PART" =~ ^D[0-9]{2}$ ]]; then
                # If STATE contains dispatcher/DIA info, determine active/passive
                DISP_GREEN=$(echo "$STATE" | grep -i dispatcher | grep -c GREEN || true)
                DIA_GREEN=$( echo "$STATE" | grep -i DIA        | grep -c GREEN || true)
                if [[ $DISP_GREEN -gt 0 && $DIA_GREEN -gt 0 ]]; then
                    ROLE="Active"
                elif [[ $DISP_GREEN -gt 0 && $DIA_GREEN -eq 0 ]]; then
                    ROLE="Passive"
                else
                    # If sapcontrol is present but no GREEN, role unknown/down
                    ROLE="Down"
                fi
            fi
        fi
    else
        # No sapcontrol: try process checks and systemctl hints
        # Check common service names for sapstartsrv and instance token
        if pgrep -f "${INSTANCE_PART}" >/dev/null 2>&1 || \
           pgrep -f "${INSTANCE_TYPE}${INSTANCE_NUMBER}" >/dev/null 2>&1 || \
           pgrep -f "sapstartsrv.*${INSTANCE_PART}" >/dev/null 2>&1; then
            RUNNING="Yes"
        else
            # try systemctl name heuristic: SAP${SID}_${INSTANCE_PART}
            if systemctl --version >/dev/null 2>&1; then
                SVCNAME="sap${SID}_${INSTANCE_PART}"
                if systemctl is-active --quiet "$SVCNAME" 2>/dev/null; then
                    RUNNING="Yes"
                fi
            fi
        fi
    fi

    if $OUTPUT_JSON; then
        # Build small json object for this instance (escape SID / TYPE)
        # Note: keep it simple; we use printf %q-like safe escaping
        obj=$(cat <<-JSON
{
  "hostname":"$HOSTNAME",
  "sid":"$SID",
  "instance_part":"$INSTANCE_PART",
  "instance_type":"$INSTANCE_TYPE",
  "instance_number":"$INSTANCE_NUMBER",
  "running":"$RUNNING",
  "role":"$ROLE"
}
JSON
)
        # strip leading tabs
        obj=$(echo "$obj")
        json_items+=("$obj")
    else
        printf "%-20s %-5s %-4s %-10s %-10s %-12s\n" \
            "$HOSTNAME" "$SID" "$INSTANCE_NUMBER" "$INSTANCE_PART" "$RUNNING" "$ROLE"
    fi

done < "$SAPSRV"

if $OUTPUT_JSON; then
    # Join json_items with commas
    printf "[\n"
    local_first=true
    for it in "${json_items[@]}"; do
        if $local_first; then
            printf "%s\n" "$it"
            local_first=false
        else
            printf ",\n%s\n" "$it"
        fi
    done
    printf "\n]\n"
fi
