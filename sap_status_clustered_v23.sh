#!/usr/bin/env bash
# sap_status_clustered_v23.sh
# Cluster-aware SAP status with Pacemaker owner fallback and remote sapcontrol checks
# - SLES 15 friendly
# - ASCS/ERS: check owner node via crm_resource; if unknown try all cluster nodes
# - HANA: role via SAPHanaSR-showAttr; running if local sapcontrol reports GREEN
# - SMDA/DAA + App servers: local checks
#
# Usage: ./sap_status_clustered_v23.sh [--owner] [--debug]

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

# header
if [[ $SHOW_OWNER -eq 1 ]]; then
    printf "%-18s %-6s %-4s %-12s %-10s %-12s %-18s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role" "Owner"
else
    printf "%-18s %-6s %-4s %-12s %-10s %-12s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
fi

# helper: list cluster nodes (crm_mon)
get_cluster_nodes() {
    if command -v crm_mon >/dev/null 2>&1; then
        crm_mon -1 -r 2>/dev/null | awk '/Online:/ {gsub(/\[|\]/,""); for(i=2;i<=NF;i++) print $i; exit}' || true
    fi
}

# helper: try crm_resource -r <res> -W -> return owner node (first column)
get_resource_owner() {
    local res="$1"
    if command -v crm_resource >/dev/null 2>&1; then
        out=$(crm_resource -r "$res" -W 2>/dev/null || true)
        # crm_resource -r res -W may print "nodeName (something...)" or just "nodeName"
        # take first token that looks like a hostname
        owner=$(printf "%s\n" "$out" | awk 'NR==1{print $1}')
        printf "%s" "$owner"
    fi
}

# helper: run sapcontrol locally as sidadm via full path
run_sapcontrol_local() {
    local sc_path="$1" sid="$2" nr="$3"
    local sidadm
    sidadm="$(echo "$sid" | tr '[:upper:]' '[:lower:]')adm"
    if [[ -x "$sc_path" ]]; then
        sudo -u "$sidadm" "$sc_path" -nr "$nr" -function GetProcessList 2>/dev/null || true
    fi
}

# helper: run sapcontrol remotely via ssh (BatchMode), return output
run_sapcontrol_remote() {
    local node="$1" sc_path="$2" sid="$3" nr="$4"
    local sidadm
    sidadm="$(echo "$sid" | tr '[:upper:]' '[:lower:]')adm"
    # use ssh options to avoid password prompt and keep short timeout
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$node" "sudo -u $sidadm $sc_path -nr $nr -function GetProcessList" 2>/dev/null || true
}

# helper: check if any node (list) reports GREEN for given sc_path and sid/nr
check_any_node_green() {
    local sc_path="$1" sid="$2" nr="$3"
    local nodes node out
    nodes=$(get_cluster_nodes)
    for node in $nodes; do
        dbg "Trying sapcontrol on $node for $sid $nr"
        out=$(run_sapcontrol_remote "$node" "$sc_path" "$sid" "$nr")
        if [[ -n "$out" ]] && printf "%s" "$out" | grep -qi "GREEN"; then
            printf "%s" "$node"
            return 0
        fi
    done
    return 1
}

# get SAPHanaSR output once
SAPHANA_SR_OUT=""
if command -v SAPHanaSR-showAttr >/dev/null 2>&1; then
    SAPHANA_SR_OUT=$(SAPHanaSR-showAttr 2>/dev/null || true)
    dbg "Captured SAPHanaSR-showAttr"
fi

# find all sapcontrol binaries under /usr/sap
# We'll iterate by discovered sapcontrol paths to find SID and instance dir
mapfile -t SAP_CTLS < <(find /usr/sap -path '*/exe/sapcontrol' -type f 2>/dev/null || true)

for SAPCTL in "${SAP_CTLS[@]}"; do
    [[ -x "$SAPCTL" ]] || continue
    INSTANCE_DIR=$(dirname "$SAPCTL" | xargs basename)
    # derive SID by moving up one directory: /usr/sap/<SID>/<INST>/exe/sapcontrol
    SID=$(dirname "$(dirname "$SAPCTL")" | xargs basename)
    # instance number and type
    # INSTANCE_DIR usually like HDB00, ASCS00, ERS01, SMDA98, D00 etc.
    NR=$(printf "%s" "$INSTANCE_DIR" | grep -oE '[0-9]{2}$' || true)
    # Some DIRs may have numbers longer, fallback:
    [[ -z "$NR" ]] && NR=$(printf "%s" "$INSTANCE_DIR" | grep -oE '[0-9]+$' || true)
    INST_TYPE=$(printf "%s" "$INSTANCE_DIR" | sed -E "s/${NR}$//" )

    RUNNING="No"
    ROLE="N/A"
    OWNER="$HOSTNAME"

    dbg "Instance found: SID=$SID INST_DIR=$INSTANCE_DIR TYPE=$INST_TYPE NR=$NR SAPCTL=$SAPCTL"

    # HANA handling: role from SAPHanaSR-showAttr (PROMOTED/DEMOTED -> PRIMARY/SECONDARY)
    if [[ "${INST_TYPE^^}" == "HDB" ]]; then
        ROLE="No SR"
        if [[ -n "$SAPHANA_SR_OUT" ]]; then
            # find line starting with hostname
            line=$(printf "%s\n" "$SAPHANA_SR_OUT" | awk -v h="$HOSTNAME" 'tolower($1)==tolower(h){print; exit}')
            if [[ -n "$line" ]]; then
                clone=$(printf "%s\n" "$line" | awk '{print $2}')
                if [[ "$clone" == "PROMOTED" ]]; then
                    ROLE="PRIMARY"
                    RUNNING="Yes"
                elif [[ "$clone" == "DEMOTED" ]]; then
                    ROLE="SECONDARY"
                    # still check local sapcontrol to mark Running=Yes if processes up
                    out=$(run_sapcontrol_local "$SAPCTL" "$SID" "$NR")
                    if [[ -n "$out" ]] && printf "%s" "$out" | grep -qi "GREEN"; then
                        RUNNING="Yes"
                    else
                        RUNNING="No"
                    fi
                fi
            else
                # no entry for this host -> No SR; we can still check local sapcontrol
                out=$(run_sapcontrol_local "$SAPCTL" "$SID" "$NR")
                if [[ -n "$out" ]] && printf "%s" "$out" | grep -qi "GREEN"; then
                    RUNNING="Yes"
                fi
            fi
        else
            # no SAPHanaSR available, fall back to local sapcontrol check
            out=$(run_sapcontrol_local "$SAPCTL" "$SID" "$NR")
            if [[ -n "$out" ]] && printf "%s" "$out" | grep -qi "GREEN"; then
                RUNNING="Yes"
            fi
        fi
    fi

    # ASCS/ERS handling: use pacemaker owner if available, otherwise fallback to trying nodes
    if [[ "${INST_TYPE^^}" =~ ^ASCS|ERS$ ]]; then
        ROLE="$INST_TYPE"
        RES_NAMES=()
        # candidate resource names to try (common patterns in your crm_resource -l output)
        RES_NAMES+=( "rsc_sapstartsrv_${SID}_${INST_TYPE}${NR}" )
        RES_NAMES+=( "rsc_sap_${SID}_${INST_TYPE}${NR}" )
        RES_NAMES+=( "rsc_sapstartsrv_${SID}_${INST_TYPE}${NR}" )
        RES_NAMES+=( "rsc_sap_${SID}_${INST_TYPE}${NR}" )

        OWNER_FOUND=""
        for res in "${RES_NAMES[@]}"; do
            dbg "Checking owner for resource candidate: $res"
            owner=$(get_resource_owner "$res" || true)
            if [[ -n "$owner" ]]; then
                OWNER_FOUND="$owner"
                OWNER="$owner"
                dbg "Owner for $res -> $owner"
                break
            fi
        done

        if [[ -n "$OWNER_FOUND" ]]; then
            # run sapcontrol on owner node (remote or local)
            if [[ "$OWNER" == "$HOSTNAME" ]]; then
                dbg "Running local sapcontrol for ASCS/ERS (owner)"
                out=$(run_sapcontrol_local "$SAPCTL" "$SID" "$NR")
            else
                dbg "Running remote sapcontrol on owner $OWNER"
                out=$(run_sapcontrol_remote "$OWNER" "$SAPCTL" "$SID" "$NR")
            fi
            if [[ -n "$out" ]] && printf "%s" "$out" | grep -qi "GREEN"; then
                RUNNING="Yes"
            else
                RUNNING="No"
            fi
        else
            # fallback: no owner found -> try all cluster nodes (ssh) and mark Running=Yes if any node reports GREEN
            dbg "No owner found via crm_resource; trying all cluster nodes for $SID $INST_TYPE$NR"
            owner_node=$(check_any_node_green "$SAPCTL" "$SID" "$NR" || true)
            if [[ -n "$owner_node" ]]; then
                RUNNING="Yes"
                OWNER="$owner_node"
                dbg "Found GREEN on node $owner_node"
            else
                RUNNING="No"
            fi
        fi
    fi

    # SMDA / DAA and other small agents: local check (pgrep or sapcontrol)
    if [[ "${INST_TYPE^^}" =~ ^SMDA|DAA$ ]]; then
        out=$(run_sapcontrol_local "$SAPCTL" "$SID" "$NR")
        if [[ -n "$out" ]] && printf "%s" "$out" | grep -qi "GREEN"; then
            RUNNING="Yes"
        else
            # fallback to pgrep
            if pgrep -f "${INST_TYPE}${NR}" >/dev/null 2>&1 || pgrep -f "sapstartsrv.*${INST_TYPE}${NR}" >/dev/null 2>&1; then
                RUNNING="Yes"
            fi
        fi
        ROLE="N/A"
    fi

    # App servers (Dxx) detection: local sapcontrol check
    if [[ "$INST_TYPE" =~ ^D[0-9]{2}$ ]]; then
        out=$(run_sapcontrol_local "$SAPCTL" "$SID" "$NR")
        DISP_GREEN=$(printf "%s" "$out" | grep -i dispatcher | grep -c GREEN || true)
        DIA_GREEN=$(printf "%s" "$out" | grep -i DIA | grep -c GREEN || true)
        if [[ $DISP_GREEN -gt 0 && $DIA_GREEN -gt 0 ]]; then
            RUNNING="Yes"
            ROLE="Active"
        elif [[ $DISP_GREEN -gt 0 ]]; then
            RUNNING="Yes"
            ROLE="Passive"
        else
            RUNNING="No"
            ROLE="Down"
        fi
    fi

    # print line
    if [[ $SHOW_OWNER -eq 1 ]]; then
        printf "%-18s %-6s %-4s %-12s %-10s %-12s %-18s\n" "$HOSTNAME" "$SID" "${NR:-}" "$INST_TYPE" "$RUNNING" "$ROLE" "$OWNER"
    else
        printf "%-18s %-6s %-4s %-12s %-10s %-12s\n" "$HOSTNAME" "$SID" "${NR:-}" "$INST_TYPE" "$RUNNING" "$ROLE"
    fi

done

exit 0
