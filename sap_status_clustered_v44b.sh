#!/usr/bin/env bash
# sap_status_clustered_v44b.sh
# v44b - fix: correct loop redirection placement + robust sapservices parsing
# Usage: ./sap_status_clustered_v44b.sh [--debug] [--owner]

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
  printf "%-15s %-6s %-4s %-8s %-8s" "Hostname" "SID" "Nr" "Type" "Running"
  [[ $SHOW_OWNER -eq 1 ]] && printf " %-10s" "Owner"
  printf "\n"
}

# utilities ----------------------------------------------------------

find_sap_exe_from_line() {
  local line="$1"
  local all
  all=$(printf "%s" "$line" | grep -o '/usr/sap/[^/ ]\+/\([^/ ]\+\)/exe' 2>/dev/null || true)
  if [[ -n "$all" ]]; then
    printf "%s" "$all" | tail -n1
  else
    printf ""
  fi
}

find_profile_from_line() {
  local line="$1"
  if [[ "$line" =~ pf=([^[:space:]]+) ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
    return
  fi
  if printf "%s" "$line" | grep -q 'pf=/usr/sap'; then
    printf "%s" "$(printf "%s" "$line" | sed -n 's/.*pf=\([^ ]*\).*/\1/p')"
    return
  fi
  printf ""
}

service_name_from_line() {
  local line="$1"
  if [[ "$line" =~ systemctl[[:space:]]+[^[:space:]]+[[:space:]]+start[[:space:]]+([A-Za-z0-9_-]+) ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
  else
    printf ""
  fi
}

owner_from_sid() {
  local sid="$1"
  if [[ -n "$sid" && "$sid" != "UNKNOWN" ]]; then
    printf "%sadm" "$(echo "$sid" | tr '[:upper:]' '[:lower:]')"
  else
    printf "UNKNOWNadm"
  fi
}

run_sapcontrol_getproc() {
  local owner="$1"; local sap_exe="$2"; local nr="$3"
  local sapcontrol
  sapcontrol="${sap_exe}/sapcontrol"
  if [[ ! -x "$sapcontrol" ]]; then
    dbg "sapcontrol not executable: $sapcontrol"
    printf ""
    return
  fi
  local cmd
  cmd="LD_LIBRARY_PATH=${sap_exe}:\$LD_LIBRARY_PATH ${sapcontrol} -nr ${nr} -function GetProcessList"
  dbg "run_sapcontrol_getproc: owner=${owner}, cmd=${cmd}"
  local out
  out=$(su - "$owner" -c "$cmd" 2>/dev/null || true)
  printf "%s" "$out"
}

is_sapcontrol_running() {
  local out="$1"
  if printf "%s" "$out" | grep -qiE 'GREEN|Running'; then
    printf "Yes"
  else
    printf "No"
  fi
}

is_sapstartsrv_running_for_profile() {
  local profile="$1"
  if ps -ef | grep -i sapstartsrv | grep -F -- "$profile" >/dev/null 2>&1; then
    printf "Yes"
  else
    printf "No"
  fi
}

sid_from_profile() {
  local profile="$1"
  local base
  base=$(basename "$profile")
  if [[ "$base" =~ ^([A-Z0-9]{2,})_([A-Z0-9]+)_ ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
  else
    if [[ "$profile" =~ /usr/sap/([^/]+)/ ]]; then
      printf "%s" "${BASH_REMATCH[1]}"
    else
      printf "UNKNOWN"
    fi
  fi
}

inst_from_profile() {
  local profile="$1"
  local base
  base=$(basename "$profile")
  if [[ "$base" =~ ^([A-Z0-9]{2,})_([A-Z0-9]+)_ ]]; then
    printf "%s" "${BASH_REMATCH[2]}"
  else
    printf ""
  fi
}

nr_from_inst() {
  local inst="$1"
  if printf "%s" "$inst" | grep -q '[0-9]'; then
    printf "%s" "$(printf "%s" "$inst" | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/p')"
  else
    printf "00"
  fi
}

# MAIN ---------------------------------------------------------------
print_header

declare -A printed_profiles=()

if [[ -f /usr/sap/sapservices ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    dbg "sapservices line: $line"

    PROFILE=$(find_profile_from_line "$line")
    SAP_EXE_DIR=$(find_sap_exe_from_line "$line")
    SERVICE_NAME=$(service_name_from_line "$line")

    if [[ -n "$SERVICE_NAME" ]]; then
      dbg "found service name: $SERVICE_NAME"
      if systemctl is-active --quiet "$SERVICE_NAME"; then
        dbg "systemctl ${SERVICE_NAME} is-active"
        EXE_PATH=$(systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | \
                 grep -o '/usr/sap/[^ ]*/[^ ]*/exe/sapstartsrv' | tail -n1 || true)
        if [[ -n "$EXE_PATH" ]]; then
          SAP_EXE_DIR=$(dirname "$EXE_PATH")
          dbg "service EXE_PATH -> $EXE_PATH"
        fi
        if [[ -z "$PROFILE" ]]; then
          PROFILE=$(systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | \
                    grep -o 'pf=[^ ]*' | sed 's/^pf=//' | tail -n1 || true)
          dbg "service-derived PROFILE -> $PROFILE"
        fi
      else
        dbg "service $SERVICE_NAME inactive"
      fi
    fi

    if [[ -n "$PROFILE" ]]; then
      SID=$(sid_from_profile "$PROFILE")
      INST=$(inst_from_profile "$PROFILE")
      NR=$(nr_from_inst "$INST")
      [[ -z "$NR" ]] && NR="00"
      OWNER=$(owner_from_sid "$SID")

      if [[ -n "${printed_profiles[$PROFILE]}" ]]; then
        dbg "skip duplicate profile $PROFILE"
        continue
      fi
      printed_profiles["$PROFILE"]=1

      TYPE="APP"
      if printf "%s" "$INST" | grep -qE '^HDB|^SMDA'; then
        TYPE="HANA"
      elif printf "%s" "$INST" | grep -qE '^ASCS'; then
        TYPE="ASCS"
      elif printf "%s" "$INST" | grep -qE '^ERS'; then
        TYPE="ERS"
      elif printf "%s" "$INST" | grep -qE '^SMDA'; then
        TYPE="SMDA"
      fi

      RUNNING="No"
      if [[ "$TYPE" == "ASCS" || "$TYPE" == "ERS" || "$TYPE" == "HANA" || "$TYPE" == "SMDA" ]]; then
        if [[ -z "$SAP_EXE_DIR" && -n "$PROFILE" && -n "$SID" && -n "$INST" ]]; then
          guess="/usr/sap/${SID}/${INST}/exe"
          if [[ -d "$guess" ]]; then
            SAP_EXE_DIR="$guess"
            dbg "guessed SAP_EXE_DIR=$SAP_EXE_DIR"
          fi
        fi

        if [[ -n "$SAP_EXE_DIR" ]]; then
          SC_OUT=$(run_sapcontrol_getproc "$OWNER" "$SAP_EXE_DIR" "$NR")
          dbg "sapcontrol first lines: $(printf '%s' "$SC_OUT" | sed -n '1,3p')"
          RUNNING=$(is_sapcontrol_running "$SC_OUT")
          if [[ -z "$SC_OUT" ]]; then
            dbg "sapcontrol returned empty, falling back to systemctl/profile checks"
            if [[ -n "$SERVICE_NAME" ]]; then
              if systemctl is-active --quiet "$SERVICE_NAME"; then
                RUNNING="Yes"
              else
                RUNNING=$(is_sapstartsrv_running_for_profile "$PROFILE")
              fi
            else
              RUNNING=$(is_sapstartsrv_running_for_profile "$PROFILE")
            fi
          fi

        else
          if [[ -n "$SERVICE_NAME" ]]; then
            if systemctl is-active --quiet "$SERVICE_NAME"; then
              RUNNING="Yes"
            else
              RUNNING=$(is_sapstartsrv_running_for_profile "$PROFILE")
            fi
          else
            RUNNING=$(is_sapstartsrv_running_for_profile "$PROFILE")
          fi
        fi
      else
        RUNNING=$(is_sapstartsrv_running_for_profile "$PROFILE")
      fi

      printf "%-15s %-6s %-4s %-8s %-8s" "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING"
      [[ $SHOW_OWNER -eq 1 ]] && printf " %-10s" "$OWNER"
      printf "\n"

    else
      SVC=$(service_name_from_line "$line")
      if [[ -n "$SVC" ]]; then
        if [[ "$SVC" =~ ^SAP([A-Z0-9]+)_([0-9]{2})$ ]]; then
          SID="${BASH_REMATCH[1]}"
          NR="${BASH_REMATCH[2]}"
          OWNER=$(owner_from_sid "$SID")
          if systemctl is-active --quiet "$SVC"; then
            EXE_PATH=$(systemctl status "$SVC" --no-pager -l 2>/dev/null | \
                     grep -o '/usr/sap/[^ ]*/[^ ]*/exe/sapstartsrv' | tail -n1 || true)
            if [[ -n "$EXE_PATH" ]]; then
              SAP_EXE_DIR=$(dirname "$EXE_PATH")
              SC_OUT=$(run_sapcontrol_getproc "$OWNER" "$SAP_EXE_DIR" "$NR")
              RUNNING=$(is_sapcontrol_running "$SC_OUT")
              INST=$(basename "$(dirname "$EXE_PATH")")
              if printf "%s" "$INST" | grep -qE '^ASCS'; then TYPE="ASCS"; elif printf "%s" "$INST" | grep -qE '^ERS'; then TYPE="ERS"; else TYPE="APP"; fi
            else
              RUNNING="Yes"
              TYPE="APP"
            fi
          else
            RUNNING="No"
            TYPE="APP"
          fi
          printf "%-15s %-6s %-4s %-8s %-8s" "$HOST" "$SID" "$NR" "$TYPE" "$RUNNING"
          [[ $SHOW_OWNER -eq 1 ]] && printf " %-10s" "$OWNER"
          printf "\n"
        fi
      fi
    fi

  done < /usr/sap/sapservices
fi

# Step 2: scan /usr/sap/*/*/exe for anything not already printed
# Redirect stderr of the entire loop to /dev/null to avoid the previous syntax error
{
  for sid_dir in /usr/sap/*/*/exe; do
    instdir=$(basename "$(dirname "$sid_dir")")
    sid=$(basename "$(dirname "$(dirname "$sid_dir")")")
    if [[ ! "$sid" =~ ^[A-Z0-9]{2,}$ ]]; then continue; fi
    if [[ ! "$instdir" =~ ^[A-Z]+[0-9]+$ ]]; then continue; fi

    possible_profile="/usr/sap/${sid}/SYS/profile/${sid}_${instdir}_${HOST}"
    if [[ -n "${printed_profiles[$possible_profile]}" ]]; then
      dbg "skip already printed $possible_profile"
      continue
    fi

    NR=$(nr_from_inst "$instdir")
    OWNER=$(owner_from_sid "$sid")
    TYPE="Unknown"
    if [[ "$instdir" =~ ^ASCS ]]; then TYPE="ASCS"
    elif [[ "$instdir" =~ ^ERS ]]; then TYPE="ERS"
    elif printf "%s" "$instdir" | grep -qE '^HDB|^SMDA'; then TYPE="HANA"; fi

    SAP_EXE_DIR="$(dirname "$sid_dir")"
    RUNNING="No"
    if [[ "$TYPE" == "ASCS" || "$TYPE" == "ERS" || "$TYPE" == "HANA" ]]; then
      SC_OUT=$(run_sapcontrol_getproc "$OWNER" "$SAP_EXE_DIR" "$NR")
      RUNNING=$(is_sapcontrol_running "$SC_OUT")
      if [[ -z "$SC_OUT" ]]; then
        RUNNING=$(is_sapstartsrv_running_for_profile "$possible_profile")
      fi
    else
      RUNNING=$(is_sapstartsrv_running_for_profile "$possible_profile")
    fi

    printf "%-15s %-6s %-4s %-8s %-8s" "$HOST" "$sid" "$NR" "$TYPE" "$RUNNING"
    [[ $SHOW_OWNER -eq 1 ]] && printf " %-10s" "$OWNER"
    printf "\n"
  done
} 2>/dev/null

exit 0
