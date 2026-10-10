# Red Hat Advanced Cluster Management (RHACM 2.16) & OpenShift GitOps: Active-Passive DR & Automated Reconnection Architecture

This repository contains production-ready Kubernetes/OpenShift manifests, automation scripts, firewall requirements, and step-by-step disaster recovery runbooks for **Red Hat Advanced Cluster Management (RHACM 2.16)** and **Red Hat OpenShift GitOps (Argo CD)** in an **Active-Passive Multi-Hub** architecture.

---

## 🏛️ Architecture Overview

The multi-cluster topology consists of:
* **Active Hub (`ocp20`):** Manages workloads, runs active Argo CD reconciliations, executes scheduled backups to S3, and enforces governance policies.
* **Passive Hub (`ocp21`):** Standby hub, continuously syncing policies, placement rules, Argo CD definitions, credentials, and resources from S3 without taking over managed clusters.
* **Workload Cluster (`ocp22`):** Managed spoke cluster, dynamically attached to the active hub.
* **S3 Object Storage (`cloud-front-bucket-jul24`):** Shared storage backend for OADP/Velero backups.

```text
+-------------------+                    +-------------------+
|  Hub 1: ocp20     |                    |  Hub 2: ocp21     |
|   (ACTIVE HUB)    |                    |  (PASSIVE HUB)    |
| ACM + GitOps +    |                    | ACM + GitOps +    |
| Active Argo CD    |                    | Standby Argo CD   |
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

## 🔄 Argo CD Active-Passive Disaster Recovery Strategy (RHACM + OADP)

According to official Red Hat documentation and architectural guidelines (*"Argo CD disaster recovery strategy using Red Hat Advanced Cluster Management and OADP"*):

### 1. Preventing "Split-Brain" Reconciliations
Running active Argo CD instances on **both** hub clusters simultaneously against the same workload cluster causes split-brain reconciliation, race conditions, and git commit locks.

To prevent split-brain:
* **Active Hub (`ocp20`):** Argo CD actively reconciles `ApplicationSet` and `Application` resources against `ocp22` using RHACM `Placement` decision bindings.
* **Passive Hub (`ocp21`):** OpenShift GitOps Operator is installed, but `GitOpsCluster` placement evaluates to **0 active clusters** (`veleroManagedClustersBackupName: skip`). Standby Argo CD remains completely passive until failover activation.

---

### 2. How Argo CD Active-Passive Failover Works

```text
[ Disaster on ocp20 ]
        │
        ▼
[ Apply Activation Restore on ocp21 ]
        │
        ▼  (veleroManagedClustersBackupName: latest)
[ Placement binds ocp22 to ocp21 GitOps ]
        │
        ▼
[ Argo CD on ocp21 discovers ocp22 ]
        │
        ▼
[ Argo CD on ocp21 resumes automated GitOps sync to ocp22 ]
```

1. During failover, `manifests/04-restore-activate.yaml` is applied to `ocp21`.
2. RHACM restores the `Placement` and `GitOpsCluster` resources onto `ocp21`.
3. `GitOpsCluster` binds `ocp22` to Argo CD in `openshift-gitops` namespace on `ocp21`.
4. Argo CD on `ocp21` discovers `ocp22`, reads Git, and seamlessly resumes automated continuous deployment to `ocp22`!

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
* `manifests/06-argocd-applicationset-dr.yaml` - Argo CD Multi-Cluster ApplicationSet with RHACM Placement generator
* `scripts/failover.sh` - Shell script automation for failover execution
* `ansible/failover-playbook.yml` - Ansible Playbook for DR failover orchestration

---

## 🔗 Official Red Hat Documentation & Reference Links

1. 📖 **Argo CD Disaster Recovery Strategy using RHACM & OADP:**
   [Argo CD disaster recovery strategy using Red Hat Advanced Cluster Management and OADP](https://www.redhat.com/en/blog/argo-cd-disaster-recovery-strategy-using-red-hat-advanced-cluster-management-and-oadp)

2. 📖 **Automatically Reconnecting Managed Clusters:**
   [A guide to automatically reconnecting managed clusters when restoring a Red Hat Advanced Cluster Management for Kubernetes 2.7+ hub cluster](https://www.redhat.com/en/blog/a-guide-to-automatically-reconnecting-managed-clusters-when-restoring-a-red-hat-advanced-cluster-management-for-kubernetes-2.7-hub-cluster)

3. 📖 **Active/Passive RHACM Hub Setup:**
   [How to move from standalone RHACM to an Active/Passive setup](https://www.redhat.com/en/blog/how-to-move-from-standalone-rhacm-to-an-active/passive-setup)

4. 📖 **ACM Backup & Restore with OADP & MinIO/S3:**
   [How to backup and restore ACM with OADP and MinIO](https://www.redhat.com/en/blog/how-to-backup-and-restore-acm-with-oadp-and-minio)
