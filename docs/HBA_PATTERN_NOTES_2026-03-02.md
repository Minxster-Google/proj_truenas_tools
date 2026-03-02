# TrueNAS HBA Pattern Notes (2026-03-02)

## Scope

- Host: `TrueNASHost` (`192.168.1.236`)
- Logs analyzed: `/var/log/kern.log*`, `/var/log/messages*`, `journalctl -k`
- Supplemental check host: `plex-ubuntu` (`/var/log/syslog*`)

## Key Findings

- WebUI log entries are persisted in standard files (`/var/log/messages`, `/var/log/kern.log`, `/var/log/syslog`).
- Repeating storage error chain on TrueNAS is consistent:
  - `FAILED Result: hostbyte=DID_TIME_OUT`
  - `I/O error, dev ...`
  - `Power-on or device reset occurred`
- Timeout-to-reset coupling is strong in historical data:
  - `1741/1741` timeouts had a same-slot reset within `120s` (in parsed window).
- Resets occur in bursts with a repeating intra-burst cadence:
  - median interval ~`33s`
  - bursts commonly `2-13` minutes in recent runs
  - latest burst observed: `2026-03-02 19:59:39 -> 20:12:48`.
- SAS PHY counters remained `0` during checks (`loss_of_dword_sync`, `invalid_dword`, `running_disparity`, `phy_reset_problem`).
- With `spinpid2_scale.sh` stopped at ~`20:44`, immediate post-stop window showed no new reset/I/O events yet; this is not proof, only an early A/B sample.

## Example Burst (2026-03-02 19:59-20:12)

- Sequential resets across multiple targets/bays (not a single isolated disk).
- Included `mpt3sas` PL event `log_info(0x31110e03)` during the burst.

## `plex-ubuntu` Correlation Check

- `plex-ubuntu` has CIFS mounts to TrueNAS (`//truenas/media`, `//truenas/raidz`).
- No kernel-level disk transport errors found in sampled logs:
  - no `I/O error`, `DID_TIME_OUT`, `Power-on or device reset occurred`, `mpt3sas`, `SATA link down`.
- Dominant errors in `plex-ubuntu` syslog were Jellyfin SQLite lock/contention events (`SQLite Error 6: database table is locked`), clustered around `05:xx` and `17:xx` windows.
- Current evidence does **not** show time alignment between plex SQLite lock bursts and the latest TrueNAS HBA reset burst (`19:59-20:12`).

## Repeatable Pattern Test

Use the reusable report script on TrueNAS:

```bash
/opt/opencode_master/proj_truenas_tools/scripts/hba_pattern_report.sh
/opt/opencode_master/proj_truenas_tools/scripts/hba_pattern_report.sh --since "2026-03-01 00:00:00"
```

Recommended A/B comparison cadence:

- Baseline snapshot, then compare at `+30m` and `+120m`.
- `+120m` is preferred to catch at least one likely burst window.

## Operational Reminder

- Temporary test change was applied earlier: `DUTY_PER_MIN=70`.
- Revert to normal after testing: `DUTY_PER_MIN=55` in `spinpid2_scale.config`.
