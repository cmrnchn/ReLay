# Gesture Window Race Verification Guide

## Overview

This document describes how to verify the gesture window race condition that causes "swipe works sometimes" issues.

**Status:** Instrumentation added to log the window activation lifecycle with precise timestamps.

## What We're Testing

**Hypothesis:** When a user initiates a title-bar swipe gesture on Window A:
1. The gesture event (CGEventTap / NSEvent.scrollWheel) arrives at ReLay
2. ReLay queries the frontmost window at that moment
3. But Window A hasn't finished activating yet (NSWindow.didBecomeKey hasn't fired)
4. So frontmost() returns the *previous* frontmost window (Window B)
5. The gesture applies to the wrong window

This is a race because window activation is asynchronous and timing varies based on system load.

## Instrumentation Added

### 1. Gesture Event Arrival (EventTapCapture.swift:156)
```
[input] scroll began allowed at (X,Y) ts=1234.567
```
**What this means:** ReLay received a valid scroll gesture at this timestamp.

### 2. Window Resolution (WindowRuntime.swift:93-98)
```
[input] gesture began: got window from hitTest, title=MyWindow ts=1234.568
[input] gesture began: got window from frontmost, title=PreviousWindow ts=1234.568
```
**What this means:** 
- `hitTest` = got window from pixel-perfect hit test (more reliable)
- `frontmost` = fell back to NSWorkspace.frontmostApplication (may be stale)
- Compare the title and source to see which window was activated

### 3. Window Query (AXWindowOps.swift:38-51)
```
[input] frontmost() via focusedWindow: MyWindow
[input] frontmost() via firstWindow: SomeWindow
[input] frontmost() returned nil
```
**What this means:** Shows HOW frontmost() determined the window (focused attribute vs. windows list).

### 4. Window Activation Notifications (main.swift)
```
[input] NSWindow.didBecomeKey: MyWindow ts=1234.562
[input] NSWindow.didBecomeMain: MyWindow ts=1234.562
```
**What this means:** Window became active at this timestamp.

## How to Verify the Race

### Test Scenario A: Race Exists (Likely)
1. **Run ReLay** with the instrumented build
2. **Open two windows** (e.g., Safari and Terminal side-by-side)
3. **Click on Safari to activate it** (but don't swipe yet)
4. **Immediately swipe** before the activation completes
5. **Examine logs** (check Console.app → ReLay):

Look for this pattern:
```
[input] NSWindow.didBecomeKey: Safari ts=1234.565      ← activation starts
[input] scroll began allowed at (X,Y) ts=1234.566      ← gesture arrives ~1ms later
[input] gesture began: got window from frontmost, title=Terminal ts=1234.567   ← WRONG WINDOW!
```

**Race Confirmed If:**
- Gesture `ts` is AFTER `didBecomeKey ts`
- But `gesture began` resolves to a different window than expected
- Or shows `got window from frontmost` instead of `hitTest`

### Test Scenario B: Race Does NOT Exist (Unlikely)
1. Perform the same actions
2. Examine logs:

```
[input] NSWindow.didBecomeKey: Safari ts=1234.565      ← activation completes
[input] scroll began allowed at (X,Y) ts=1234.575      ← gesture arrives ~10ms later
[input] gesture began: got window from hitTest, title=Safari ts=1234.576   ← CORRECT WINDOW
```

**Race Not Confirmed If:**
- `didBecomeKey` always completes BEFORE gesture arrives
- Gesture always resolves to the expected window
- Hit test succeeds most of the time

## Interpreting the Results

### Log Format: Timestamp Analysis

All logs include `ts=NNNN.NNN` (system uptime in seconds with millisecond precision).

**Calculate delay between events:**
```
Event B ts - Event A ts = elapsed time (in seconds)
e.g., 1234.567 - 1234.560 = 0.007 seconds = 7 milliseconds
```

### Key Comparisons

| Comparison | Meaning |
|-----------|---------|
| `didBecomeKey ts` < `scroll began ts` | Window was fully activated before gesture |
| `scroll began ts` < `didBecomeKey ts` | Gesture arrived before window activated |
| `gesture began` resolves to same window as `didBecomeKey` | Correct window targeted |
| `gesture began` resolves to different window | **RACE DETECTED** |
| Source shows `hitTest` | Hit test worked (more reliable) |
| Source shows `frontmost` | Fell back to workspace API (less reliable) |

## Collecting Logs for Analysis

### Option 1: Console.app (GUI)
1. Open **Console.app**
2. Search for `subsystem: input` or just `ReLay`
3. Perform a gesture
4. Copy relevant log lines

### Option 2: Command Line
```bash
# Stream all ReLay logs in real-time
log stream --predicate 'subsystem == "com.relay.app"' --level debug

# Or grep from existing logs
log show --predicate 'subsystem == "input"' | grep -E 'scroll|gesture|NSWindow|frontmost'
```

### Option 3: Console Inside ReLay Settings
If ReLay has a built-in console (check SettingsWindow.swift), logs should appear there.

## Reproduction Steps (For Race Condition)

1. **Disable hit test temporarily** (edit WindowRuntime.swift line 93-94):
   ```swift
   let hitTestWindow = nil  // Disable hit test to force frontmost()
   window = TitleBarHitTest.windowForGesture(at: intent.location)
       ?? AXWindowOps.frontmost()
   ```

2. Repeat test scenario A above

3. This should make the race *more likely to appear* because you're forcing reliance on frontmost()

## If Race Is Confirmed

The fix is already documented in the memory:
- Capture window ONCE on `.began` phase
- Store in `state.activeWindow`
- Use the same window for entire gesture lifecycle
- Never re-query `frontmost()` mid-gesture

See: `/Users/cameroncohen/.claude/projects/-Users-cameroncohen-Developer-projects-ReLay/memory/gesture_window_race.md`

## If Race Is NOT Confirmed

- Hit test is doing its job reliably
- Current architecture is sound
- Document findings and consider if we can remove the fallback to frontmost()
- Or keep it as a safety net

---

**Next Steps:**
1. Build this version: `swift build`
2. Run the instrumented binary
3. Perform gestures and collect logs
4. Post findings in a summary document with log excerpts
5. Then decide: fix or close
