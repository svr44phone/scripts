import json
import sys
import requests

# --- CONFIG ---
suma_host = "https://suma"  # SUSE Manager hostname
suma_endpoint = f"{suma_host}/rhn/manager/api"
verify_ssl = False  # change to CA file path for production
suma_login = "spupgapi"
suma_password = "August2025$"

def api_post(path, payload=None, cookies=None):
    resp = requests.post(f"{suma_endpoint}{path}", json=payload, cookies=cookies, verify=verify_ssl)
    if not resp.ok:
        print(f"[ERROR] {resp.status_code}: {resp.text}")
        resp.raise_for_status()
    return resp

# --- LOGIN ---
login_payload = {"login": suma_login, "password": suma_password}
login_resp = api_post("/auth/login", login_payload)
cookies = login_resp.cookies
print("[INFO] Logged in to SUSE Manager")

# --- GET SYSTEM SID ---
hostname = "myserver"
sid_resp = api_post("/system/getId", {"name": hostname}, cookies)
sid_data = sid_resp.json().get("result", [])
if not sid_data:
    sys.exit(f"No system found with hostname: {hostname}")
sid = sid_data[0]["id"]
print(f"[INFO] System {hostname} has SID {sid}")

# --- GET MIGRATION TARGETS ---
targets_resp = api_post("/system/listLatestMigrations", {"sid": sid}, cookies)
targets = targets_resp.json().get("result", [])
if not targets:
    sys.exit("No migration targets available.")

print("[INFO] Available migration targets:")
print(json.dumps(targets, indent=2))

# --- SELECT TARGET ---
desired_sp = "sp7"
base_channel = next(
    (t["base_channel_label"] for t in targets if desired_sp in t["base_channel_label"].lower()),
    None
)
if not base_channel:
    print(f"[WARN] {desired_sp} migration target not found.")
    print("Pick manually from:")
    for t in targets:
        print(f" - {t['base_channel_label']}")
    sys.exit(1)

print(f"[INFO] Selected base channel: {base_channel}")

# --- DRY-RUN MIGRATION ---
schedule_payload = {
    "sid": sid,
    "baseChannelLabel": base_channel,
    "optionalChildChannels": [],
    "dryRun": True,
    "allowVendorChange": True,
    "earliestOccurrence": "2025-09-01T00:00:00Z"
}
migration_resp = api_post("/system/scheduleProductMigration", schedule_payload, cookies)
action_id = migration_resp.json().get("result")
print(f"[DRY-RUN] Migration scheduled. Action ID: {action_id}")
