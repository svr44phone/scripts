Alright — let’s break the plan up into **three separate Puppet Tasks** for reuse, and then orchestrate them in one **Puppet Plan**.  

This way you can run each check individually or combine them into larger plans — which is a best practice in Puppet Enterprise.

---

## Step 1 — Create 3 Puppet Tasks

We'll make 3 tasks:

1. **service_check** — checks if required services are running  
2. **failed_units_check** — checks if there are any failed systemd units  
3. **disk_space_check** — verifies free space in `/var` and `/opt` meets your minimum requirement

We'll use **task metadata files (`.json`)** so you can run them via the PE console, Bolt, or orchestrator.

---

### **1. service_check**
**File:** `tasks/service_check.sh`
```bash
#!/bin/bash
services="$PT_services"
IFS=',' read -ra svcs <<< "$services"

missing=()

for svc in "${svcs[@]}"; do
  if ! systemctl is-active --quiet "$svc"; then
    missing+=("$svc")
  fi
done

if [ ${#missing[@]} -ne 0 ]; then
  echo "Missing services: ${missing[*]}"
  exit 1
else
  echo "All required services are running."
  exit 0
fi
```

**File:** `tasks/service_check.json`
```json
{
  "description": "Check if required services are running",
  "parameters": {
    "services": {
      "type": "String",
      "description": "Comma-separated list of services to check"
    }
  },
  "implementations": [
    {"name": "service_check.sh", "requirements": ["shell"]}
  ]
}
```

---

### **2. failed_units_check**
**File:** `tasks/failed_units_check.sh`
```bash
#!/bin/bash
failed_units=$(systemctl --failed --no-legend --plain | awk '{print $1}')

if [ -n "$failed_units" ]; then
  echo "Failed units detected: $failed_units"
  exit 1
else
  echo "No failed units detected."
  exit 0
fi
```

**File:** `tasks/failed_units_check.json`
```json
{
  "description": "Check if any systemd units are in failed state",
  "parameters": {},
  "implementations": [
    {"name": "failed_units_check.sh", "requirements": ["shell"]}
  ]
}
```

---

### **3. disk_space_check**
**File:** `tasks/disk_space_check.sh`
```bash
#!/bin/bash
min_gb="$PT_min_free_gb"
mounts="/var /opt"

failed=()

for mount in $mounts; do
  free_gb=$(df -BG "$mount" | awk 'NR==2 {print $4}' | sed 's/G//')
  if [ "$free_gb" -lt "$min_gb" ]; then
    failed+=("$mount:${free_gb}GB")
  fi
done

if [ ${#failed[@]} -ne 0 ]; then
  echo "Low space on: ${failed[*]}"
  exit 1
else
  echo "Sufficient space on /var and /opt."
  exit 0
fi
```

**File:** `tasks/disk_space_check.json`
```json
{
  "description": "Check disk space on /var and /opt",
  "parameters": {
    "min_free_gb": {
      "type": "Integer",
      "description": "Minimum free GB required"
    }
  },
  "implementations": [
    {"name": "disk_space_check.sh", "requirements": ["shell"]}
  ]
}
```

---

## Step 2 — Orchestration Plan Using Tasks

**File:** `plans/sles_full_check.pp`
```puppet
plan sles_full_check (
  TargetSpec $nodes,
  Optional[Integer] $min_free_gb = 3
) {
  $required_services = [
    'besclient.service',
    'cagent.service',
    'cribl-edge.service',
    'falcon-sensor.service',
    'illumio-ven.service',
    'mount_checker.service',
    'node_exporter.service',
    'puppet.service',
    'puppet_agent_exporter.service',
    'pxp-agent.service',
    'venv-salt-minion.service'
  ]

  $failed_nodes = []

  # Check required services  
  $svc_result = run_task('service_check', $nodes,
    services => $required_services.join(',')
  )
  foreach $r in $svc_result {
    if $r['status'] == 'failure' {
      notice("Service check failed on ${r['target']}: ${r['result']['_output']}")
      $failed_nodes += [$r['target']]
    }
  }

  # Check for failed units
  $failed_units_result = run_task('failed_units_check', $nodes)
  foreach $r in $failed_units_result {
    if $r['status'] == 'failure' {
      notice("Failed units found on ${r['target']}: ${r['result']['_output']}")
      $failed_nodes += [$r['target']]
    }
  }

  # Check disk space
  $disk_result = run_task('disk_space_check', $nodes, min_free_gb => $min_free_gb)
  foreach $r in $disk_result {
    if $r['status'] == 'failure' {
      notice("Disk space check failed on ${r['target']}: ${r['result']['_output']}")
      $failed_nodes += [$r['target']]
    }
  }

  if !empty($failed_nodes) {
    fail("Checks failed on nodes: ${failed_nodes.join(', ')}")
  } else {
    notice("All checks passed on all nodes")
  }
}
```

---

## Step 3 — Usage

Put this in a Puppet module structure:

```
modules/
  sles_checks/
    tasks/
      service_check.sh
      service_check.json
      failed_units_check.sh
      failed_units_check.json
      disk_space_check.sh
      disk_space_check.json
    plans/
      sles_full_check.pp
    metadata.json
```

**Run the plan:**
```bash
bolt plan run sles_checks::sles_full_check \
  nodes='["vm1.example.com","vm2.example.com"]' \
  min_free_gb=3
```

Or from the PE console, choose the plan and pass parameters.

---

### **Advantages of splitting into tasks:**
- You can run `bolt task run service_check` on demand, without the whole plan.
- Easier to troubleshoot — run each check individually.
- Reusable in other plans (disk check can be reused anywhere).
- PE Console can display per-task output nicely.

---

✅ If you want, I can also add **structured JSON output** instead of plain text, so plans can process the results without parsing strings — would make alerting/automation more robust.  

Do you want me to upgrade these tasks to **return structured JSON results** so they’re more machine-friendly?
