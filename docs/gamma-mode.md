# Gamma-mode validation

The multiply overlay built and ran on a built-in Liquid Retina XDR display with
macOS 27.0 beta (26A5388g), but produced no visible brightness boost. A plain EDR
fill became brighter but covered the desktop; an additive wash visibly reduced
contrast. Neither observation proves a particular WindowServer implementation.

The successful alternative uses a small EDR trigger and uniform, unclipped
scaling of the captured per-channel gamma tables. The user confirmed that the
result looked correct after testing the gamma implementation.

## Table size matters

On this display, the native gamma capacity is 1024. Writing an unclipped gain of
1.1 using 1024 entries produced readback with boosted midtones but white at 1.0.
Reapplying after EDR engagement did not change that. Writing 256 entries retained
white at approximately 1.1 in both 256- and 1024-entry readbacks. The implementation
therefore captures a 256-entry baseline for boosted writes and independently saves
the full native table for restoration.

This use of values above 1.0 is outside the range documented for
`CGSetDisplayTransferByTable`. It is verified on this test system, not a promise
of identical behavior on every display or macOS version.

## Measured results

A bounded eight-second trial at gain 1.25 measured all native RGB entries while
boosted and after exit:

| Check | Result |
| --- | --- |
| Current EDR headroom | 1.2 before, approximately 2.66667 during |
| RGB black endpoints | Exactly 0 |
| RGB white endpoints | Approximately 1.25 |
| All 1024 entries per channel | Strictly increasing; no highlight plateau |
| Maximum error from uniformly scaling the captured curve | 0.000000164 |
| Restoration after exit | All 3072 RGB samples matched the original exactly |

These are transfer-table and headroom measurements, not photometric measurements
of panel black luminance or nits. The visual confirmation supplements them.

## Regression and manual checks

`make test` checks unclipped highlights, zero black, per-channel calibration,
shadow proportions, unchanged baselines, and rejection of invalid/already boosted
tables. Session tests also check the 256-entry write path, exact native-table
restoration, exclusive ownership, and retry after a failed restore using a fake
display API. Tests do not change the physical display. The earlier SDR-clipped
implementation fails the highlight tests.

For a manual test, quit other gamma/brightness tools, run `xdr-boost --gamma`,
select 1.10 then 1.25, and inspect a grayscale image with near-black and near-white
detail. Verify that turning the mode off or quitting restores normal display
output. The app bundle uses gamma by default on macOS 27 and newer; its launch
still starts with boost off.

Gamma mode currently targets one screen. Other macOS versions, external displays,
and interactions with HDR video, Night Shift, or other color-management tools
need additional testing. Do not run competing gamma tools simultaneously.
