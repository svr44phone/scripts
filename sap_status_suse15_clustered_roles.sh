#!/usr/bin/env bash
# sap_status_suse15_clustered_roles.sh
# Purpose: Detect SAP instance status on SUSE Linux Enterprise Server 15 with Pacemaker clusters
# Adds HANA System Replication role mapping (Primary/Secondary)
# Supports: SAP HANA, ENSA2 ASCS/ERS, standalone instances
# Usage: ./sap_status_suse15_clustered_roles.sh [--debug] [--owner]

set -o pipefail
DEBUG=0
SHOW_OWNER=0
for a in "$@"; do
  case "$a" in
    --debug) DEBUG=1 ;;
    --owner) SHOW_OWNER=1 ;;
  esac
done

dbg() { [[ $DEBUG -eq 1 ]] && printf "DEBUG: %s\n" "$*" >&2; }

HOST=$(hostname -s)
print_header() {
  printf "%-15s %-6s %-4s %-8s %-10s %-12s" "Hostname" "SID" "Nr" "Type" "Running" "Role"
  [[ $SHOW_OWNER -eq 1 ]] && printf " %-10s" "Owner"
  printf "\n"
}

print_header

# Detect Pacemaker cluster
if systemctl is-active --quiet pacemaker; then
  dbg "Pacemaker cluster detected"
  crm_mon -r -1 | awk '/SAPInstance|SAPHana/{print}' | while read -r line; do
    res_name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | grep -o '(Started)' | sed 's/[()]//g')
    ROLE="-"
    if [[ "$res_name" =~ SAPInstance_([A-Z0-9]+)_([A-Z]+)([0-9]+) ]]; then
      SID="${BASH_REMATCH[1]}"
      INST="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
      NR="${BASH_REMATCH[3]}"
      TYPE="${BASH_REMATCH[2]}"
    elif [[ "$res_name" =~ SAPHana_([A-Z0-9]+) ]]; then
      SID="${BASH_REMATCH[1]}"
      INST="HDB"
      NR="00"
      TYPE="HANA"
      # Extract role info from crm_mon details
      ROLE=$(crm_mon -r -1 | awk -v sid=$SID '/SAPHanaController/ && $0 ~ sid {print}' | grep -o 'PRIMARY\|SECONDARY' | head -n1)
      [[ -z "$ROLE" ]] && ROLE="Unknown"
    else
      SID="UNKNOWN"; INST="UNKNOWN"; NR="00"; TYPE="Unknown"
    fi
    OWNER="${SID,,}adm"
    RUNNING="No"
    [[ "$state" == "Started" ]] && RUNNING="Yes"
    printf "%-15s %-6s %-4s %-8s %-10s %-12s" "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
    [[ $SHOW_OWNER -eq 1 ]] && printf " %-10s" "$OWNER"
    printf "\n"
  done
else
  dbg "No cluster detected, fallback to sapservices"
fi

# Fallback: parse /usr/sap/sapservices
if [[ -f /usr/sap/sapservices ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    PROFILE=$(echo "$line" | grep -o 'pf=[^ ]*' | sed 's/^pf=//')
    SAP_EXE_DIR=$(echo "$line" | grep -o '/usr/sap/[^/ ]\+/[^/ ]\+/exe' | tail -n1)
    if [[ -n "$PROFILE" ]]; then
      SID=$(basename "$PROFILE" | cut -d_ -f1)
      INST=$(basename "$PROFILE" | cut -d_ -f2)
      NR=$(echo "$INST" | sed 's/[^0-9]*//g')
      [[ -z "$NR" ]] && NR="00"
      OWNER="${SID,,}adm"
      TYPE="APP"
      [[ "$INST" =~ ^ASCS ]] && TYPE="ASCS"
      [[ "$INST" =~ ^ERS ]] && TYPE="ERS"
      [[ "$INST" =~ ^HDB ]] && TYPE="HANA"
      RUNNING="No"
      ROLE="-"
      if [[ -n "$SAP_EXE_DIR" ]]; then
        SC_OUT=$(su - "$OWNER" -c "LD_LIBRARY_PATH=${SAP_EXE_DIR}:\$LD_LIBRARY_PATH ${SAP_EXE_DIR}/sapcontrol -nr ${NR} -function GetProcessList" 2>/dev/null)
        [[ "$SC_OUT" =~ GREEN|Running ]] && RUNNING="Yes"
      fi
      printf "%-15s %-6s %-4s %-8s %-10s %-12s" "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING" "$ROLE"
      [[ $SHOW_OWNER -eq 1 ]] && printf " %-10s" "$OWNER"
      printf "\n"
    fi
  done < /usr/sap/sapservices
fi

exit 0
