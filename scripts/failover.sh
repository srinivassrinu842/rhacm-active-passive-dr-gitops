#!/usr/bin/env bash
# Failover Automation Script: ocp20 (Active) -> ocp21 (Passive)
set -euo pipefail

echo "==> Starting Failover from ocp20 to ocp21..."

# 1. Stop backups on ocp20 if reachable
echo "==> Stopping BackupSchedule on ocp20..."
oc --context=ocp20 delete backupschedule schedule-acm -n open-cluster-management-backup --ignore-not-found=true || true

# 2. Delete passive restore on ocp21
echo "==> Removing passive sync Restore on ocp21..."
oc --context=ocp21 delete restore restore-passive-sync -n open-cluster-management-backup --ignore-not-found=true

# 3. Apply Activation Restore on ocp21
echo "==> Applying Activation Restore on ocp21..."
oc --context=ocp21 apply -f manifests/04-restore-activate.yaml

# 4. Wait for restore completion
echo "==> Waiting for Restore to finish on ocp21..."
until [ "$(oc --context=ocp21 get restore restore-acm-activate -n open-cluster-management-backup -o jsonpath='{.status.phase}')" == "Finished" ]; do
    echo "Restore in progress... waiting 10s"
    sleep 10
done
echo "==> Activation Restore Finished!"

# 5. Enable BackupSchedule on ocp21
echo "==> Enabling BackupSchedule on ocp21..."
oc --context=ocp21 apply -f manifests/02-backup-schedule-acm.yaml

# 6. Enable Passive Sync on ocp20
echo "==> Enabling Passive Sync Restore on ocp20..."
oc --context=ocp20 apply -f manifests/03-restore-passive-sync.yaml || true

echo "==> Failover Complete! ocp21 is now the Active Hub."
