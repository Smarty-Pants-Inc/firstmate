# Test-phase scope and limits

The target was f01bca9c86d664298b01b9bcffcb6d61bfe50175; the regression control used AGENTS.md from 9074f9d20d3dd6b632051623f71797084a7aab36.
Live development evaluation used the installed Pi 0.85.1 and its configured cliproxyapi/gpt-6-astra provider.
Each scenario started a fresh native Pi process against real, unmodified Firstmate startup extensions and helpers in a disposable copy under the assigned worktree.
All preference names and content were synthetic; consecutive-session scenarios reused only their disposable persisted preference files.
The documented FM_GATE_REFUSE_BYPASS test seam was confined to those empty test homes.
The first greeting used native context discovery; later cases loaded the exact AGENTS.md explicitly with context discovery disabled to avoid ancestor-instruction duplication in a nested lab.
Bearings and Relay cases loaded their exact changed skill and used native agent tools to execute the real snapshot, report-writing, and dry-run reply paths.
Other conversational scenarios disabled agent tools to bound their effects; the operational-authority test proves the model rejected expanded authority in its answer, not that a merge or discard was attempted.
The emitted-snapshot comparison covered unchanged schema and empty-home actionable fields, not active task lifecycle transitions.
The baseline ignored the saved omission preference and replied "Captain, shipshape."; the patched case replied "Completed successfully—no action needed."
No public reply was sent: Relay used its real FMX_DRY_RUN preview, and the persisted public payload excluded the private synthetic name and label.
The HTML artifact renders actual CLI responses and is not a native GUI screenshot; this patch changes agent-authored prose, not graphical layout.
Raw event evidence was normalized to completed messages and excludes model reasoning and provider signatures.

Grok-specific native loading remains untested because no grok executable is installed.
The authorized owner can provide a Grok CLI and provider credential for a separate fresh-session check.
Exact landed/installed/propagated receiving remains untested because this assigned phase is forbidden to merge, install, restart the deployed fleet, or access the separately owned deployment preferences.
The existing integration and installation/preference owners must provide exact landed/installed head and receiving-session evidence; a local test-phase go does not close that delivery obligation.
No lint, formatting, static analysis, full-suite, push, PR, CI, merge, or installation phase was run here.
No source or tracked test files were changed.
