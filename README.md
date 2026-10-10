# Red Hat Advanced Cluster Management (RHACM 2.16) & OpenShift GitOps: Active-Passive DR & Automated Reconnection Architecture

This repository contains production-ready Kubernetes/OpenShift manifests, automation scripts, firewall requirements, and step-by-step disaster recovery runbooks for **Red Hat Advanced Cluster Management (RHACM 2.16)** and **Red Hat OpenShift GitOps (Argo CD)** in an **Active-Passive Multi-Hub** architecture.

---

## 🏛️ Architecture Overview

The multi-cluster topology consists of:
* **Active Hub (`ocp20`):** Manages workloads, runs scheduled backups to S3, and enforces governance policies.
* **Passive Hub (`ocp21`):** Standby hub, continuously syncing policies, placement rules, credentials, and definitions from S3 without taking over managed clusters.
* **Workload Cluster (`ocp22`):** Managed spoke cluster, dynamically attached to the active hub.
* **S3 Object Storage (`cloud-front-bucket-jul24`):** Shared storage backend for OADP/Velero backups.

```text
+-------------------+                    +-------------------+
|  Hub 1: ocp20     |                    |  Hub 2: ocp21     |
|   (ACTIVE HUB)    |                    |  (PASSIVE HUB)    |
| ACM + GitOps +    |                    | ACM + GitOps +    |
| BackupSchedule    |                    | Sync Restore      |
+---------+---------+                    +---------+---------+
          |                                        |
          |  (Backups every 2h)                    | (Syncs every 10m)
          v                                        v
  +--------------------------------------------------------+
  |             Shared AWS S3 / Object Storage             |
  |               (cloud-front-bucket-jul24)               |
  +--------------------------------------------------------+
                               ^
                               | (Auto-reconnects via MSA)
                      +--------+--------+
                      | Spoke: ocp22    |
                      | (Workload)      |
                      +-----------------+
```

---

## 🌐 Network & Firewall (FW) Port Requirements

Post-cluster deployment, the following network ports and vSphere switch security settings **MUST** be open/configured for intra-cluster communication, VIP management, and hub-to-spoke synchronization.

### 1. vSphere Virtual Switch Security Policies (CRITICAL)
For OpenShift IPI/UPI on vSphere with API VIP (`172.16.0.210` / `172.16.0.211`), Keepalived/VRRP requires virtual MAC address changes. Set the following to **Accept** on the vSphere PortGroup (`VM Network`):
* 🔓 **MAC Address Changes:** `Accept`
* 🔓 **Forged Transmits:** `Accept`
* 🔓 **Promiscuous Mode:** `Accept` *(Standard vSwitch requirement)*

### 2. Firewall Port Matrix

| Source | Destination | Port / Protocol | Direction | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| Workload Nodes / Bastion | Hub API VIP (`172.16.0.210`/`.211`) | `6443/TCP` | Inbound to Hub | Kubernetes API Server access |
| RHCOS Nodes (Initramfs) | Hub API VIP (`172.16.0.210`/`.211`) | `22623/TCP` | Inbound to Hub | Machine Config Server (MCS) Ignition fetch |
| Managed Spoke Klusterlet | Hub API VIP | `6443/TCP`, `443/TCP` | Outbound from Spoke | Klusterlet agent hub registration & heartbeat |
| Hub Cluster | Managed Spoke API | `6443/TCP` | Outbound from Hub | ManagedServiceAccount & ManifestWork reconciliation |
| Hub Clusters (Both) | S3 Object Storage | `443/TCP` | Outbound | OADP / Velero backup & restore sync |
| Hub Nodes | Hub Nodes (VRRP VIP) | IP Protocol `112` (VRRP) | Bidirectional | Keepalived Virtual IP failover |
| Submariner / Inter-Cluster | Managed Spokes | `500/UDP`, `4500/UDP`, `4800/UDP` | Bidirectional | IPsec tunnel for direct pod-to-pod networking |

---

## ⚙️ Prerequisites Post-Cluster Deployment

1. **DNS Resolution:**
   * `api.ocp20.mylab.local` $\rightarrow$ `172.16.0.210`
   * `api-int.ocp20.mylab.local` $\rightarrow$ `172.16.0.210`
   * `api.ocp21.mylab.local` $\rightarrow$ `172.16.0.211`
   * `api-int.ocp21.mylab.local` $\rightarrow$ `172.16.0.211`
   * `api.ocp22.mylab.local` $\rightarrow$ Workload API IP

2. **Operators Installed on Both Hub Clusters:**
   * Red Hat Advanced Cluster Management (RHACM) Operator (`open-cluster-management` namespace).
   * Red Hat OpenShift GitOps Operator (`openshift-gitops` namespace).
   * OADP Operator (`open-cluster-management-backup` namespace).

---

## 🤖 Automated Cluster Reconnection (`useManagedServiceAccount: true`)

By default, manually imported clusters require running `oc apply -f import.yaml` after a failover because RHACM does not store master keys for imported clusters.

To achieve **100% automated failover without manual re-importing**, this architecture uses RHACM's **`useManagedServiceAccount: true`** feature in `BackupSchedule`:

1. `BackupSchedule` sets `useManagedServiceAccount: true`.
2. RHACM automatically provisions an `auto-import-account` `ManagedServiceAccount` for `ocp22`.
3. The `auto-import-account` token is backed up to S3 under `acm-credentials`.
4. When `ocp21` restores with `veleroManagedClustersBackupName: latest`, RHACM uses the token to automatically re-login to `ocp22` and update its bootstrap secret to point to `ocp21`.

---

## 🔄 Disaster Recovery Failover & Failback Runbooks

### 🚨 Failover Runbook: Active (`ocp20`) $\rightarrow$ Standby (`ocp21`)

1. **Stop Backup Schedule on Primary (`ocp20`):**
   ```bash
   oc --context=ocp20 delete backupschedule schedule-acm -n open-cluster-management-backup
   ```
2. **Remove Passive Sync on Standby (`ocp21`):**
   ```bash
   oc --context=ocp21 delete restore restore-passive-sync -n open-cluster-management-backup
   ```
3. **Trigger Activation Restore on `ocp21`:**
   ```bash
   oc --context=ocp21 apply -f manifests/04-restore-activate.yaml
   ```
4. **Enable Backup Schedule on `ocp21` (New Active):**
   ```bash
   oc --context=ocp21 apply -f manifests/02-backup-schedule-acm.yaml
   ```
5. **Enable Passive Sync on `ocp20` (New Standby):**
   ```bash
   oc --context=ocp20 apply -f manifests/03-restore-passive-sync.yaml
   ```

---

### 🔄 Failback Runbook: Standby (`ocp21`) $\rightarrow$ Active (`ocp20`)

1. **Stop Backup Schedule on `ocp21`:**
   ```bash
   oc --context=ocp21 delete backupschedule schedule-acm -n open-cluster-management-backup
   ```
2. **Remove Passive Sync on `ocp20`:**
   ```bash
   oc --context=ocp20 delete restore restore-passive-sync -n open-cluster-management-backup
   ```
3. **Trigger Activation Restore on `ocp20`:**
   ```bash
   oc --context=ocp20 apply -f manifests/04-restore-activate.yaml
   ```
4. **Enable Backup Schedule on `ocp20`:**
   ```bash
   oc --context=ocp20 apply -f manifests/02-backup-schedule-acm.yaml
   ```
5. **Enable Passive Sync on `ocp21`:**
   ```bash
   oc --context=ocp21 apply -f manifests/03-restore-passive-sync.yaml
   ```

---

## 📜 Repository Structure

* `manifests/01-oadp-dpa.yaml` - OADP DataProtectionApplication CR
* `manifests/02-backup-schedule-acm.yaml` - RHACM BackupSchedule CR with `useManagedServiceAccount: true`
* `manifests/03-restore-passive-sync.yaml` - RHACM Passive Sync Restore CR (`veleroManagedClustersBackupName: skip`)
* `manifests/04-restore-activate.yaml` - RHACM Failover Activation Restore CR (`veleroManagedClustersBackupName: latest`)
* `manifests/05-gitops-integration.yaml` - OpenShift GitOps ManagedClusterSetBinding, Placement, and GitOpsCluster CRs
* `scripts/failover.sh` - Shell script automation for failover execution
* `ansible/failover-playbook.yml` - Ansible Playbook for DR failover orchestration

---

## 🔗 Official Red Hat Documentation & Reference Links

1. 📖 **Automatically Reconnecting Managed Clusters:**
   [A guide to automatically reconnecting managed clusters when restoring a Red Hat Advanced Cluster Management for Kubernetes 2.7+ hub cluster](https://www.redhat.com/en/blog/a-guide-to-automatically-reconnecting-managed-clusters-when-restoring-a-red-hat-advanced-cluster-management-for-kubernetes-2.7-hub-cluster)

2. 📖 **Active/Passive RHACM Hub Setup:**
   [How to move from standalone RHACM to an Active/Passive setup](https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup)

3. 📖 **ACM Backup & Restore with OADP & MinIO/S3:**
   [How to backup and restore ACM with OADP and MinIO](https://www.redhat.com/en/blog/how-to-backup-and-restore-acm-with-oadp-and-minio)

4. 📖 **Argo CD & GitOps Disaster Recovery Strategy:**
   [Argo CD disaster recovery strategy using Red Hat Advanced Cluster Management and OADP](https://www.redhat.com/en/blog/argo-cd-disaster-recovery-strategy-using-red-hat-advanced-cluster-management-and-oadp)
