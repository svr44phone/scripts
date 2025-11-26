#!/usr/bin/env bash
# sap_status_suse15_minimal_ensa2_hostaware.sh
# Purpose: Minimal SAP status check for SUSE 15
# Outputs: Hostname, SID, Nr, Running (Yes/No)
# Supports: Clustered HANA, ENSA2 ASCS/ERS clusters (only if active on this node), standalone HANA, standalone ASCS/ERS, APP servers
# Ignores SMDA and DAA instances

set -o pipefail
HOST=$(hostname -s)

print_header() {
  printf "%-15s %-6s %-4s %-8s
" "Hostname" "SID" "Nr" "Running"
}

print_header

CRM_OUT=""
if systemctl is-active --quiet pacemaker; then
  CRM_OUT=$(crm_mon -r -1 2>/dev/null)
fi

declare -A printed_instances=()

# Cluster detection with ENSA2 handling and node-based check
if [[ -n "$CRM_OUT" ]]; then
  echo "$CRM_OUT" | awk '/SAPInstance|SAPHana/{print}' | while read -r line; do
    res_name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | grep -o '(Started)' | sed 's/[()]//g')
    SID="UNKNOWN"; NR="00"; NODE=""

    # Extract node name from line (crm_mon format: resource (Started) node)
    NODE=$(echo "$line" | awk '{print $NF}')

    if [[ "$res_name" =~ SAPInstance_([A-Z0-9]+)_ASCS([0-9]+) ]]; then
      SID="${BASH_REMATCH[1]}"; NR="${BASH_REMATCH[2]}"
    elif [[ "$res_name" =~ SAPInstance_([A-Z0-9]+)_ERS([0-9]+) ]]; then
      SID="${BASH_REMATCH[1]}"; NR="${BASH_REMATCH[2]}"
    elif [[ "$res_name" =~ SAPInstance_([A-Z0-9]+)_([A-Z]+)([0-9]+) ]]; then
      SID="${BASH_REMATCH[1]}"; NR="${BASH_REMATCH[3]}"
    elif [[ "$res_name" =~ SAPHana_([A-Z0-9]+) ]]; then
      SID="${BASH_REMATCH[1]}"; NR="00"
    fi

    if [[ "$SID" != "UNKNOWN" && "$NODE" == "$HOST" ]]; then
      key="${SID}_${NR}"
      if [[ -z "${printed_instances[$key]}" ]]; then
        printed_instances[$key]=1
        RUNNING="No"; [[ "$state" == "Started" ]] && RUNNING="Yes"
        printf "%-15s %-6s %-4s %-8s
" "$HOST" "$SID" "$NR" "$RUNNING"
      fi
    fi
  done
fi

# Fallback: parse /usr/sap/sapservices, ignore SMDA and DAA
if [[ -f /usr/sap/sapservices ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    PROFILE=$(echo "$line" | grep -o 'pf=[^ ]*' | sed 's/^pf=//')
    if [[ -n "$PROFILE" ]]; then
      SID=$(basename "$PROFILE" | cut -d_ -f1)
      INST=$(basename "$PROFILE" | cut -d_ -f2)
      # Skip SMDA and DAA
      if [[ "$INST" =~ ^SMDA || "$INST" =~ ^DAA ]]; then
        continue
      fi
      NR=$(echo "$INST" | sed 's/[^0-9]*//g'); [[ -z "$NR" ]] && NR="00"
      key="${SID}_${NR}"
      if [[ -z "${printed_instances[$key]}" ]]; then
        printed_instances[$key]=1
        RUNNING="No"
        if ps -ef | grep -i sapstartsrv | grep -F -- "$PROFILE" >/dev/null 2>&1; then
          RUNNING="Yes"
        fi
        printf "%-15s %-6s %-4s %-8s
" "$HOST" "$SID" "$NR" "$RUNNING"
      fi
    fi
  done < /usr/sap/sapservices
fi

# Profile scanning fallback, ignore SMDA and DAA
for sid_dir in /usr/sap/*/*/exe; do
  instdir=$(basename "$(dirname "$sid_dir")")
  sid=$(basename "$(dirname "$(dirname "$sid_dir")")")
  # Skip SMDA and DAA
  if [[ "$instdir" =~ ^SMDA || "$instdir" =~ ^DAA ]]; then
    continue
  fi
  possible_profile="/usr/sap/${sid}/SYS/profile/${sid}_${instdir}_${HOST}"
  [[ ! -f "$possible_profile" ]] && continue
  NR=$(echo "$instdir" | sed 's/[^0-9]*//g'); [[ -z "$NR" ]] && NR="00"
  key="${sid}_${NR}"
  if [[ -z "${printed_instances[$key]}" ]]; then
    printed_instances[$key]=1
    RUNNING="No"
    if ps -ef | grep -i sapstartsrv | grep -F -- "$possible_profile" >/dev/null 2>&1; then
      RUNNING="Yes"
    fi
    printf "%-15s %-6s %-4s %-8s
" "$HOST" "$sid" "$NR" "$RUNNING"
  fi
done

exit 0
