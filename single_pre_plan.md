Got it — you want a **Puppet Enterprise plan** that will:

1.  Connect to a list of SUSE 15 SP5 VMs (TargetSpec)
2.  Check if a specific list of services are **running**.
3.  Check if **any services are in failed state**.
4.  Check that **/var** and **/opt** each have at least **3GB free space**.
5.  Report failures and stop the plan if any check fails.

Below is a complete Puppet Bolt plan in **Puppet language** that implements what you asked.

* * *

Puppet Plan: `sles_service_and_disk_checks`
-------------------------------------------

[HLJS PUPPET !WHITESPACE-PRE CODE BLOCK]
plan sles_service_and_disk_checks (
  TargetSpec $nodes,
  Optional[Integer] $min_free_gb = 3
) {
  # Services to verify
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
    'venv-salt-minion.service',
  ]

  $failed_nodes = []

  # Check services state
  foreach $node in $nodes {
    notice("Checking required services on ${node}...")

    # Run service status checks in one command so it's efficient
    $svc_command = "for svc in ${required_services.join(' ')}; do
      systemctl is-active --quiet \"$svc\" || echo \"SERVICE_NOT_RUNNING:$svc\";
    done"
    $svc_result = run_command($svc_command, $node)

    if $svc_result[0]['stdout'] =~ /SERVICE_NOT_RUNNING/ {
      notice("Node ${node} has services not running: ${svc_result[0]['stdout']}")
      $failed_nodes += [$node]
    }

    # Check failed units
    $failed_svc_result = run_command("systemctl --failed --no-legend --plain | awk '{print $1}'", $node)
    if strip($failed_svc_result[0]['stdout']) != '' {
      notice("Node ${node} has failed units: ${failed_svc_result[0]['stdout']}")
      $failed_nodes += [$node]
    }

    # Check disk space for /var and /opt
    $disk_command = "df -BG /var /opt | awk 'NR>1 {print $6,$4}'"
    $disk_result = run_command($disk_command, $node)

    $lines = split(strip($disk_result[0]['stdout']), "\n")
    $disk_ok = true
    foreach $line in $lines {
      $parts = split($line, ' ')
      $mount_point = $parts[0]
      $free_gb = regsubst($parts[1], 'G$', '') # remove trailing G

      if Integer($free_gb) < $min_free_gb {
        notice("Node ${node} mount ${mount_point} has less than ${min_free_gb}GB free (${free_gb}GB)")
        $disk_ok = false
      }
    }

    if $disk_ok == false {
      $failed_nodes += [$node]
    }
  }

  if !empty($failed_nodes) {
    fail("Checks failed on nodes: ${failed_nodes.join(', ')}")
  } else {
    notice("All checks passed on all nodes")
  }
}


--- END CODE BLOCK ---

* * *

### How This Works

*   **Services List**:
    In `$required_services`, you list all services you expect to be running.
    The plan loops through each node and executes `systemctl is-active --quiet` for each service.
    If any are not active, they are reported.
    
*   **Failed Units**:
    `systemctl --failed --no-legend --plain` returns failed services. If any are found, the node is flagged.
    
*   **Free Space Check**:
    Runs `df -BG` for `/var` and `/opt`, parses free space. If less than `$min_free_gb`, flags the node.
    
*   **Fail Logic**:
    Any failing condition adds the node to `$failed_nodes`. Plan calls `fail()` at the end if any node failed — causes Bolt/Puppet Enterprise to report error.
    

* * *

### Running the Plan

Save the file in your control repo under `plans/sles_service_and_disk_checks.pp` (or module’s `plans/`).

Then run:

[HLJS BASH !WHITESPACE-PRE CODE BLOCK]
bolt plan run sles_service_and_disk_checks \
  nodes='["vm1.example.com","vm2.example.com"]' \
  min_free_gb=3


--- END CODE BLOCK ---

* * *

### Useful Extensions

In Puppet Enterprise, you can:

*   Wrap these shell checks into proper **Puppet Tasks** for re-use.
*   Use **notify blocks** to send alerts via Slack/email.
*   Schedule runs via **PE orchestrator**.

* * *

Do you want me to **refactor this into separate tasks** (service check, failed-service check, disk check) so you can reuse them individually and compose them in other plans?
That often makes maintenance easier in PE.
