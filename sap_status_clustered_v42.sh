#!/bin/bash

DEBUG=0
[[ "$1" == "--debug" ]] && DEBUG=1

HOSTNAME=$(hostname)

dbg() {
    [[ $DEBUG -eq 1 ]] && echo "DEBUG: $*" >&2
}

print_header() {
    printf "%-15s %-7s %-5s %-10s %-7s %-8s\n" "Hostname" "SID" "Nr" "Type" "Running" "Role"
}

extract_sid() {
    # Given: /usr/sap/D3G/SYS/profile/D3G_D00_host
    echo "$1" | sed -n 's#.*/\([A-Z0-9]\{3\}\)_.*#\1#p'
}

extract_nr() {
    # Given D00 → 00
    echo "$1" | sed 's/^[A-Z]\+//'
}

detect_running() {
    local profile="$1"

    # check if any sapstartsrv belongs to this profile
    if ps -ef | grep -i sapstartsrv | grep -q "$profile"; then
        echo "Yes"
    else
        echo "No"
    fi
}

print_header

# -------------------------------
# Parse APP instances from /usr/sap/sapservices
# -------------------------------
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" =~ pf=([^[:space:]]+) ]]; then
        PROFILE="${BASH_REMATCH[1]}"
        SID=$(extract_sid "$PROFILE")
        INST=$(basename "$PROFILE" | cut -d_ -f2)
        NR=$(extract_nr "$INST")

        dbg "sapservices: PROFILE=$PROFILE SID=$SID INST=$INST NR=$NR"

        RUNNING=$(detect_running "$PROFILE")

        printf "%-15s %-7s %-5s %-10s %-7s %-8s\n" \
            "$HOSTNAME" "$SID" "$NR" "APP" "$RUNNING" "APP"
    fi

done < /usr/sap/sapservices

# -------------------------------
# Additional instances (ASCS/ERS/HANA)
# -------------------------------
for SID in /usr/sap/*; do
    SID=$(basename "$SID")
    [[ ! "$SID" =~ ^[A-Z0-9]{3}$ ]] && continue

    for instpath in /usr/sap/$SID/*; do
        inst=$(basename "$instpath")
        [[ ! "$inst" =~ ^[A-Z]+[0-9]+$ ]] && continue

        NR=$(extract_nr "$inst")

        case "$inst" in
            ASCS*) TYPE="ASCS" ;;
            ERS*)  TYPE="ERS"  ;;
            HDB*)  TYPE="HANA" ;;
            SMDA*) TYPE="SMDA" ;;
            *) continue ;;
        esac

        PROFILE="/usr/sap/$SID/SYS/profile/${SID}_${inst}_${HOSTNAME}"

        RUNNING=$(detect_running "$PROFILE")

        dbg "extra: SID=$SID INST=$inst NR=$NR TYPE=$TYPE PROFILE=$PROFILE RUNNING=$RUNNING"

        printf "%-15s %-7s %-5s %-10s %-7s %-8s\n" \
            "$HOSTNAME" "$SID" "$NR" "$TYPE" "$RUNNING" "$TYPE"
    done
done
