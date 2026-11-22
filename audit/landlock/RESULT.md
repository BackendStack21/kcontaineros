# Track: landlock

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Landlock track audit of kContainerOS 0.2.0. Two findings; details below and in final text.

## What held

- Run-or-write rule holds in all 8 configurations.
- Program directories immutable under init even for root.
- Symlinks never followed when rules are built.
- Hard links do not cross the rule boundary.
- KCOS_EXEC and KCOS_DEV parsing strict and fail-safe.

## Findings

### F1 — Any device node opens with access mode 3 and is ioctl-able under init

- Severity: auditor **high**, reviewer **high**
- Reviewer's verdict: reproduced

The Landlock ruleset does not handle the ioctl-device right (ABI 5; kernel is ABI 8), so an access-mode-3 open of any device node succeeds and ioctl works, contradicting the README claim that only standard devices can be opened. Reachable with a plain passed device as nobody and for every host device under privileged; bounded by capability drop.

Reproduction:

```
Build audit/landlock image, run init with a plain rtc device not named in KCOS_DEV as nobody, open rtc with access mode 3 and issue the read-time ioctl.
```

Expected: Device not in allowlist cannot be opened under init.

Observed: read open denied, mode-3 open ok, read-time ioctl returns live value.

Reviewer: Real and undocumented. An open with access mode 3 asks Landlock for neither read nor write, and the device-ioctl right is not handled, so every device node whose file permissions grant both r and w to the caller can be opened and driven by ioctl under init. The README headline claim is false as written, which is why I keep high. Bounds: no read() or write() on the descriptor, no capabilities, so capability-gated ioctls fail; the practical exposure is ioctl-driven devices such as kvm, dri, loop-control or an unnamed --device. I only issued read-only ioctls on rtc and tun and did not open any block device. Fix direction: handle LANDLOCK_ACCESS_FS_IOCTL_DEV when ABI >= 5 and grant it only on the allowlisted devices; document the gap for ABI < 5. Write-up: audit/landlock/REPRODUCTION.md

### F2 — Landlock fails open with only a warning on non-kernel ruleset-build failure

- Severity: auditor **low**, reviewer **info**
- Reviewer's verdict: reproduced

confine_files returning false (e.g. under file-descriptor exhaustion) makes init warn and continue with no Landlock rule; README documents fail-open only for kernels lacking Landlock.

Reproduction:

```
Run init under a very low open-file limit; init prints Landlock-unavailable and proceeds.
```

Expected: Fail closed or a message distinguishing unavailable from could-not-install.

Observed: init warns Landlock unavailable and runs with no Landlock rule.

Reviewer: The mechanism is real: with RLIMIT_NOFILE exactly 3, landlock_create_ruleset gets EMFILE, init prints the 'unavailable' warning and runs the command with no Landlock rule, on a kernel that has Landlock. I lower the auditor's severity from low to info because the state cannot be reached through docker run (runc fails well above that limit) and cannot be caused by code already under the lockdown. It needs a custom entrypoint that lowers the limit before exec'ing init, which is the image author's choice. Limits of 4 and 5 fail closed as designed. What remains is an inaccurate warning text and a README that names only the old-kernel cause. It is loud, not silent. Cheap hardening: fail closed (exit 125) when the ABI is >= 2 but the ruleset cannot be created or applied.

