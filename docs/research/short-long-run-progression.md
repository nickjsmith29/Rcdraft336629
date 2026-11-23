# Long runs too short for a decoupling reading (#170)

Checked 22 Nov 2026. Every source below was opened and read. Numbers in brackets match SPEC.md section 12.

## The gap

SPEC 3.3 lets a long run grow only when pace-to-HR decoupling stays under 5% at the target duration, and the app computes decoupling only on steady runs with more than 40 minutes of moving time. A long run with 40 minutes or less records no decoupling, so it can never qualify, and for a beginner, comeback or low-volume plan the long run never grows.

## What the sources say

- **Decoupling's window.** TrainingPeaks (Friel) gives the practical running test as one to two hours at aerobic threshold, and says one hour is usually enough for shorter events [25]. 220 Triathlon (Friel) ties the measure to long, race-like efforts [26]. Marathon Handbook gives no minimum length [27]. None of them uses decoupling to decide how long the next long run should be; all treat it as a sign of aerobic fitness. None sets a hard minimum run length, so the app's 40-minute cut-off is a product choice.
- **Growing short long runs.** RunnersConnect (Gaudette) adds about one extra mile, or about 10 minutes, a week at a comfortable pace, with down weeks, and gives an alternating method for injury-prone or new runners [28]. Fleet Feet's beginner long-run guide keeps the long run conversational, at an effort of about 4 to 5 out of 10 and mostly in zone 2, growing by about 10% a week (no source given) [29]. Nike questions the 10% rule [30]; its claims about trials of larger rises were not checked here.

## Reading

Below the length where decoupling can be read, the sources grow a short long run when it was finished at an easy, conversational effort, by about 10 minutes a week, inside the usual load limits. The app already steps long runs by 10 minutes (`longRunStepSeconds`), and its 3.5 guardrails (the single-run spike rule and the weekly caps) still bound every step. "Easy" is read from heart rate, against the runner's own zone 2 (SPEC 3.2), which the watch records on any run. All of this is coaching practice, not trial evidence. Evidence: weak (expert and coaching sources only).

## Owner's decision

Option 1, "Easy and finished" (Nick, 22 Nov 2026, #170), offered as: a short long run counts when it was finished and its average heart rate was at or under the zone-2 cap. In the app's terms, "short" means 40 minutes or less of moving time (a run of exactly 40:00 gets no decoupling reading, so it takes this path), and "at or under the cap" means within zone 2: the cap is the top of zone 2 and exclusive, so a value equal to it already counts as zone 3. SPEC 3.3 states the rule. Options not chosen: completion alone; leaving short long runs where they are.
