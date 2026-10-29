# CHPC Storage Tiers Reference

## Quick Reference Table

| Filesystem | Path | Size | User Quota | Auto-delete | Backed up | Best for |
|---|---|---|---|---|---|---|
| Home | `$HOME` (`/home/hpc/$USER`) | — | 50 GB soft / 75 GB hard | Never | No (optional $) | Scripts, configs, small results |
| VAST Scratch | `/scratch/general/vast` | 1 PB | 50 TB | 60-day inactivity | No | Default for all job I/O |
| NFS Scratch | `/scratch/general/nfs1` | 595 TB | None | 60-day inactivity | No | Fallback when VAST is full |
| RAI VAST | `/scratch/rai/vast1` | 1.8 PB | 50 TB / 100M inodes | None | No | AI/ML (requires RAI SLURM partition) |
| Local Scratch | `/scratch/local/$USER/$SLURM_JOB_ID` | 40–500 GB/node | — | Job end / 2-week idle | No | Single-node high-IOPS |
| Group Space | `/uufs/chpc.utah.edu/common/home/<group>/` | Purchased | Configurable | Never | Optional ($) | Shared group data (not for job I/O) |
| Pando | S3/Globus endpoint | $150/TB/5yr | — | Never | No (is the backup) | Archive of completed datasets |
| Redwood | PE environment | — | 50 GB home + 250 GB project | Never | Yes | PHI/PII/HIPAA only |

---

## Checking Quotas and Capacity

Run `mychpc storage` to see:
- Personal `$HOME` usage vs. quota (shown for `/home/hpc`)
- Overall capacity % for each filesystem
- Group spaces available to the user and their fill level

There is no per-user scratch quota check — the 50 TB VAST cap is enforced at the filesystem level only.

---

## Scratch Purge Policy

- Scratch is scrubbed **weekly** for files with more than 60 days of inactivity
- Inactivity = no read or write access for 60+ days; accessing a file resets the clock
- RAI VAST (`/scratch/rai/vast1`) has **no** auto-delete — but treat it as scratch, not archive

---

## Home Directory Quota Tiers

- At **50 GB**: 7-day grace period — reduce usage before grace expires
- At **75 GB** (hard limit): writes blocked; OnDemand and FastX sessions fail to launch
- SSH access remains available at hard limit for cleanup
- Over-quota `$HOME` does not affect running jobs, only new submissions and interactive sessions

---

## Local Scratch Notes

- Path auto-created per job: `/scratch/local/$USER/$SLURM_JOB_ID`
- Size varies by node: 40–500 GB
- Software-encrypted; purged on node reboot or 2+ weeks of idle time
- Files are **inaccessible from other nodes** — not suitable for multi-node jobs
- Set `TMPDIR=/scratch/local` if a tool needs a large temp directory (avoids small RAM-disk `/tmp`)

---

## Group Space Notes

- Purchased storage: $150/TB without backups, $450/TB with backups (5-year term)
- NFS-mounted — not designed for high-I/O job workloads
- Available groups shown in `mychpc storage` output; path pattern: `/uufs/chpc.utah.edu/common/home/<groupname>/`
- Can be mounted on local machines (VPN required off-campus)

---

## RAI VAST Access

- Requires an `rai` or `rai-gpu` partition to be visible in `mychpc batch` output
- Funded by the One-U Responsible AI Initiative
- 1.8 PB total, 50 TB per-user quota, 100 million inode limit
- No automatic purge — still not a permanent archive; move completed data to Pando or group space

---

## Pando (Object Storage Archive)

- Ceph with 6+3 erasure coding
- $150/TB for 5 years; user-managed data movement
- Access via: Globus endpoint, S3 API, rclone, Cyberduck
- General Environment only — not for regulated/sensitive data
- Not backed up (Pando itself is used as a backup destination for other systems)

---

## ARC-A / ARC-B (State-wide Archive)

- ARC-A: 2.8 PB disk at Downtown Data Center
- ARC-B: 7.2 PB tape at Tonaquint Data Center (two copies written)
- Free during grant period; per-TB charge after
- 50 TB per-group allocation limit
- Open/published data only — no security-restricted data

---

## Redwood (Protected Environment)

- Separate login nodes — do not copy PHI/PII/HIPAA data to general clusters
- Home: 50 GB per user; Project space: 250 GB base allocation
- Backed up; DTN nodes available for transfers (40 Gbps, VPN required)

---

## Reference Links

- Storage services overview: https://www.chpc.utah.edu/resources/storage_services.php
- Storage policies (retention, quotas, backup): https://www.chpc.utah.edu/documentation/policies/3.1FileStoragePolicies.php
- Data transfer and services: https://www.chpc.utah.edu/documentation/data_services.php
