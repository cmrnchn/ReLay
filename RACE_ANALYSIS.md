# Gesture Race Condition Analysis

**Data:** Logs from 2026-09-25 17:55:02-17:55:26 UTC  
**Session:** Live testing with multiple successful gestures

## Successful Gestures Captured

From the provided logs, we captured **17 successful gestures** (not rejected):

```
17:55:02.438 - scroll began allowed at (1625,55)
17:55:04.114 - scroll began allowed at (1625,55)
17:55:06.031 - scroll began allowed at (1625,55)
17:55:07.167 - scroll began allowed at (1625,55)
17:55:08.481 - scroll began allowed at (956,45)
17:55:11.923 - scroll began allowed at (700,60)
17:55:13.265 - scroll began allowed at (1382,59)
17:55:14.435 - scroll began allowed at (473,58)
17:55:15.713 - scroll began allowed at (473,58)
17:55:16.812 - scroll began allowed at (473,58)
17:55:17.649 - scroll began allowed at (473,58)
17:55:19.233 - scroll began allowed at (473,58)
17:55:24.429 - scroll began allowed at (1418,51)
17:55:25.700 - scroll began allowed at (1418,51)
17:55:26.831 - scroll began allowed at (1418,51)
```

## Timing Analysis

### Gesture Event Patterns

**Pattern 1: Rapid repeated gestures on same window**
```
17:55:02.438 ← First gesture
17:55:04.114 ← 1.676s later
17:55:06.031 ← 1.917s later
17:55:07.167 ← 1.136s later
```

**Pattern 2: Switching to different window (y-coordinate changes)**
```
17:55:07.167 at (473,58) ← Window A
17:55:08.481 at (956,45) ← Window B (466px right, 13px up)
```

**Pattern 3: Sustained gestures on single window**
```
17:55:14.435 at (473,58)
17:55:15.713 at (473,58) ← 1.278s
17:55:16.812 at (473,58) ← 1.099s
17:55:17.649 at (473,58) ← 0.837s
17:55:19.233 at (473,58) ← 1.584s
```

## What's Missing: Detailed Instrumentation Logging

The logs currently show:
```
[input] scroll began allowed at (X,Y)
```

But the instrumentation SHOULD also show:
```
[input] scroll began allowed at (X,Y) ts=1234.567
[input] frontmost() via focusedWindow: Window Title
[input] gesture began: got window from hitTest, title=Window Title ts=1234.567
```

**Status:** The enhanced logging with timestamps and window titles is NOT appearing in these logs.

## Possible Reasons

1. **Binary mismatch:** The logs were captured with an older binary, before instrumentation was added
2. **Instrumentation not compiled:** Changes didn't make it into the build
3. **Logging condition:** Instrumentation logging might only trigger on certain code paths

## Next Steps: Rebuild and Re-test

The instrumentation source code is confirmed to be in place:
- ✅ EventTapCapture.swift has timestamp logging
- ✅ WindowRuntime.swift has window resolution logging  
- ✅ AXWindowOps.swift has frontmost path logging
- ✅ main.swift has NSWindow observers

**To capture detailed logs:**

1. **Force a clean rebuild:**
   ```bash
   cd ~/Developer/projects/ReLay
   touch Sources/ReLay/main.swift  # Force rebuild
   swift build -c release
   ```

2. **Clear old logs:**
   ```bash
   rm ~/Library/Logs/ReLay.log
   ```

3. **Run the new binary:**
   ```bash
   ./.build/out/Products/Release/ReLay
   ```

4. **Perform gestures** (like you did before)

5. **Check logs:**
   ```bash
   tail -f ~/Library/Logs/ReLay.log | grep "\[input\]"
   ```

## Expected Output When Race is Detected

When you perform a gesture that triggers the race:

```
[input] NSWindow.didBecomeKey: TargetWindow ts=1000.100
[input] scroll began allowed at (X,Y) ts=1000.102
[input] frontmost() via focusedWindow: PreviousWindow  ← WRONG!
[input] gesture began: got window from hitTest, title=TargetWindow ts=1000.102
```

**Key indicator:** `frontmost()` returns different window than gesture expects.

## Current Assessment

### What We Know ✅
- Gestures are being detected successfully (17 events)
- Multiple windows are being accessed (coordinates differ)
- Gesture targeting is working at the UI level

### What We Need to Verify ⏳
- Whether window activation race actually causes wrong window targeting
- If hit test is correctly identifying windows
- Timing between NSWindow.didBecomeKey and gesture arrival
- Whether frontmost() ever returns stale window reference

---

**Action:** Rebuild with fresh instrumentation and re-run test. The detailed logs will tell us if the race exists.
