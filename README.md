# Boox Refresh Manager for KOReader

A KOReader plugin designed for Onyx Boox e-ink devices running in **Regal mode** (via Boox OS E-ink Center).

## Overview
When an Onyx Boox device is set to Regal mode, the Onyx Qualcomm/SDM display controller monitors screen update frequency. When UI interactions (such as opening the Bookshelf start menu, tapping buttons, or navigating dialogs) trigger rapid successive redraws or multi-slice animations, the hardware display compositor trips into an aggressive full-screen hardware flash (`waveform_mode = 16`, `Rect[0 0 2480 1860]`) to scrub perceived motion.

**Boox Refresh Manager** eliminates UI and Bookshelf flashing entirely while keeping Boox OS in Regal mode for reading.

## Features
- **Waveform Clamping in UI Contexts**: Intercepts `UIManager:setDirty` and `Screen` refresh requests, cleanly downgrading `flashui`, `flashpartial`, and UI-driven `full` refreshes to non-flashing partial updates (`ui` / `partial`).
- **Temporal Refresh Coalescing (35ms Window)**: Aggregates rapid successive `Screen:refreshUI` redraws and multi-strip slice animations into a single atomic bounding-box update. Prevents the Qualcomm SDM compositor queue from detecting high-frequency redraw churn.
- **Multi-Slice Animation Suppression**: Bypasses intermediate `Screen:yieldToEPDC` stalls during UI slice animations.
- **Native Document Reading Quality**: Passes document page turns in `ReaderUI` through completely untouched. Regal mode contrast, sharpness, and reader-configured periodic full refreshes function exactly as intended.
- **Clean Lifecycle**: Flushes pending bounding-box updates and cancels scheduled timers during device sleep/suspend to prevent wakeups during kernel freeze.

## Installation
Clone or copy `boox-refresh-manager.koplugin` into your KOReader `plugins/` directory:
```bash
/sdcard/koreader/plugins/boox-refresh-manager.koplugin/
```
