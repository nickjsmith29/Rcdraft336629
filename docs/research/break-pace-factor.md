# Paces after a break: the Daniels return factor (SPEC 3.5 rule 4, #28)

Source read: [8] VDOT O2 (Daniels), "VDOT adjustments for time off from running", published 14 Feb 2018 (last modified 23 Mar 2022), https://news.vdoto2.com/?p=1285. Read on 23 Nov 2026.

## What [8] says

- A table of factors by time off from running. FVDOT-1 is for no cross-training, FVDOT-2 for cross-training during the break. The pre-setback VDOT is multiplied by the factor.
- FVDOT-1 rows: up to 5 days 1.000; 6 days 0.997; 7 days 0.994; 10 days 0.985; 14 days 0.973; 21 days 0.952; 28 days 0.931; 35 days 0.910; 42 days 0.889; 49 days 0.868; 56 days 0.847; 63 days 0.826; 70 days 0.805; 72 days or more 0.800.
- FVDOT-2 rows: up to 5 days 1.000; 6 days 0.998; 7 days 0.997; 10 days 0.992; 14 days 0.986; 21 days 0.976; 28 days 0.965; 35 days 0.955; 42 days 0.994 (out of line with its neighbours, likely a typo in the source); 49 days 0.934; 56 days 0.923; 63 days 0.913; 70 days 0.902; 72 days or more 0.900.
- Worked example: two weeks off without cross-training gives a return VDOT of 97.3% of the pre-setback VDOT.
- It also adjusts for a change in body weight (pre-break weight times VDOT, divided by current weight, before the factor).
- Once racing resumes, race times set an updated VDOT.

## What [8] doesn't say

- How to handle day counts between the rows. The FVDOT-1 rows from 5 to 70 days lie on one straight line (0.003 lower per day), but the page gives only the rows.
- How or when to lift the factor back to 100% after a return to training. Its only exit is a new VDOT from race times.
- How a VDOT change maps to training speeds. The app paces from a race anchor by Riegel (SPEC 3.9) and from the easy-pace sample, not from VDOT.

## Choices in the spec (all heuristics except the table)

- Days off: consecutive days with no running, with every day of a break week (SPEC 3.5 rule 4's weekly reading) counted as off even if it holds a short run. This is the longer of the two readings, so the larger slow-down.
- Between rows: take the longer row's value (the larger slow-down) rather than interpolating.
- Cross-training: never used. The app doesn't ask (no manual modes, CLAUDE.md scope) and doesn't read cross-training from the runner's data. The no-cross-training column is the more conservative one, and the other column has a suspect row.
- Speed: training speeds are scaled by the factor. Not checked against Daniels' own pace tables, which haven't been read.
- Weight adjustment: not used. The spec reads no body weight, and the step matters only when weight changed during the break.
- Ending: after a short break, lifted back over the return ramp (factor, halfway, 100% from week 3). After a longer break, held until a race or time trial after the break gives a new anchor, as [8] says. Only a run marked as a race or time trial ends it; a best effort from training does not. Through the third week after the break no training pace is faster than before the break.
- Source: [8] is a coaching table, not a study.
- For the code PR: `.timeTrialLast20Min` is not an anchor candidate today (`markedRaces` takes `.race` only), so the code needs a way for a marked time trial to end the factor.
