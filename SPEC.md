# Personal Running Coach: Build Spec

Version 0.6, November 21, 2026. Owner: Nick. Builder: Claude Code.

Changes in 0.6: 3.5 rule 6 defines a cut week by two limits (the spike rule and a 20% weekly rise) and grows the plan back by the higher of 20% over the week run and the return steps (65 / 82.5 / 100% of plan), measured against the original plan until a week is back at plan; 3.5 rule 7 bounds the weeks after a pain stop of more than 14 days by the return's own ceilings (#107).

## 1. Purpose

A personal running coach for any runner with an iPhone and Apple Watch. It does what Runna does well (adaptive plans, watch sync, live voice cues) and fixes what it does poorly: it starts from the runner's own history, reads physiology and not just pace, adapts automatically, and shows concrete proof of improvement.

Motivation is the core product requirement. Runners stay motivated by seeing measurable improvement, so every feature should feed numbers to the progress dashboard.

### Goals

1. Build each plan from past runs and health data first, then from a short goal interview.
2. Base every rule on published training science, and label anything that is only a heuristic.
3. Adapt the plan from pace and physiology together (heart rate relative to the athlete's own thresholds, heart-rate drift, cadence fade, power, grade, weather), automatically, with no manual dials.
4. Sync every workout to the watch and coach in real time by voice, more accurately than Runna.
5. Show improvement on a dashboard the runner wants to open.
6. Work for any runner: every personal value (zones, thresholds, paces, history, health baselines) is learned at runtime from that runner's own data. Nothing user-specific is hard-coded.

### Non-goals

- Strength or mobility sessions.
- Manual volume or difficulty sliders, "not feeling 100%" mode, holiday mode. The engine handles missed days and missed targets on its own.
- Shoe tracking.
- Social features, several runners sharing one device, or an App Store release (for now). Each install serves one runner and learns everything from that runner's data.

## 2. Learning the runner's data (nothing hard-coded)

Everything personal is derived at runtime from the runner's own data: Apple Health first, Strava only if the runner connects it. The app ships with no one's heart rate, paces, races or health history.

What the app learns from the data:
- History: runs, weekly volume, long runs, races and best efforts.
- Physiology: LTHR and zones from sustained efforts (3.2), easy pace at a fixed heart rate, decoupling, cadence trend, running power, resting HR, HRV and sleep baselines.
- Context: treadmill share, typical training days and session lengths.

Data problems the importer must expect in any runner's history:
- **Duplicates:** the same run recorded twice with the same start time, for example once by a third-party plan app and once by the watch.
- **Missing streams:** cadence, power or HR absent for stretches, often after a device or app change. Flag the gap; never fill it with guesses.
- **Untrustworthy zones from other apps:** zones estimated from age rather than measured. Replace them with zones from the runner's own efforts.
- **Treadmill runs:** they need their own handling (3.8).
- **No weather:** activities usually carry none, so weather comes from a weather service.

If the runner's easy runs sit near their threshold heart rate, the app should notice, confirm it with a short field test, and slow easy runs down. That is often the biggest early gain.

Committed test fixtures are synthetic or simulated recordings only. A runner who wants to replay their own exported runs keeps them in the git-ignored `Fixtures/local/` folder on their own machine; they are never committed and never needed for CI.

Cold start: a runner with no qualifying hard effort gets no LTHR estimate and no zones from a formula. The app schedules a short field test (3.2) and uses heart-rate-capped easy running until it has one.

## 3. Training science the engine follows

Each rule below says how strong the evidence is. Where the evidence is weak, the engine uses the rule conservatively and lets the athlete's own data override it over time.

### 3.1 Intensity distribution (most running easy)
- A 2024 meta-analysis (Oliveira et al., Sports Medicine; 17 studies, 437 athletes) found polarized training improved VO2peak slightly more than other distributions (SMD 0.24), mainly in interventions under 12 weeks and in highly trained athletes. Time-trial performance and threshold measures did not differ.
- **Rule:** keep roughly 75 to 85% of weekly running time below the aerobic threshold, with the rest split between threshold and VO2max work. Pyramidal or polarized are both acceptable; the non-negotiable is that easy runs are truly easy by heart rate. Strength of evidence: moderate.

### 3.2 Zones from the athlete's own data
- Never use age-predicted max HR once real data exists.
- Estimate LTHR from races and hard efforts (average HR over a sustained race or the last 20 minutes of a 30-minute solo time trial) and confirm with a scheduled field test.
- Zones: LTHR-based (a common Friel-style split, for example zone 2 at about 85 to 89% of LTHR) plus pace zones from current race fitness. Recompute after every race, test or 4 weeks of data.

### 3.3 Aerobic fitness from heart-rate drift
- Aerobic decoupling compares pace-to-HR (or power-to-HR) in the first and second halves of a steady run. Under 5% indicates good aerobic endurance at that intensity; 5 to 10% moderate; over 10% means the effort was above aerobic threshold (Friel, TrainingPeaks).
- **Rule:** compute decoupling on every steady run over 40 minutes; progress long runs only when decoupling stays under 5% at the target duration.
  - **When the hold is under the easy-run floor (owner's decision, #159).** The app's shortest-run floor (20 minutes, the plan builder's easy-run floor; a product heuristic, not a research figure) gives way to this hold. When the length this rule allows for the next long run is under the floor, the long run is held at that length, never longer than its plan, whether it is planned under, at or above the floor. It is not raised to the floor (#121) or turned into a rest day by this hold. The 3.5 guardrails still apply after the hold. Before this, long runs planned under the floor were rested, and a rest day records no long run, so the hold could never move. Holding at the allowed length keeps long runs happening and keeps this rule's limit on long-run growth. It doesn't by itself lift the hold: decoupling is measured only on runs over 40 minutes, so a held run under that records no decoupling; the next sub-bullet says how such a run can still count. Heuristic.
  - **Long runs too short for a decoupling reading (owner's decision, #170).** Decoupling is a measure for long aerobic runs (the practical test is one to two hours, one hour usually enough for events under an hour [25]), and no source uses it to decide how long the next long run should be. Short long runs are grown in coaching practice when they were finished at an easy, conversational effort [28][29], by about 10 minutes a week [28]. Each recent long run is judged by its own moving time. A long run with 40 minutes or less of moving time is too short for a decoupling reading (the decoupling minimum is strictly more than 40 minutes), so it counts toward this rule when it was finished (the gate's completion share of its planned time) and its main-part average heart rate, the same one the easy-run cap uses, stayed below the top of the runner's own zone 2 (3.2), judged against the zones in use when the run was recorded. A value equal to that top is zone 3 and doesn't count. A run with no heart rate, or a run saved before heart rate was kept for long runs, doesn't count. Neither does any short long run while the runner has no heart-rate zones yet; the app checks this when it gathers the inputs for an adaptation, since the coaching logic is always given zones. The app never guesses missing data. A long run with more than 40 minutes of moving time still needs decoupling under 5%. Everything else is as for longer runs: the same number of recent qualifying long runs, the same step (about 10 minutes), and the 3.5 guardrails on every step. Coaching practice, not trial evidence; the 40-minute line and the completion share are heuristics.

### 3.4 Readiness from HRV, resting HR and sleep
- HRV-guided training shows a small positive effect on VO2max in a meta-analysis of six trials (Granero-Gallegos et al. 2020), with weak trial quality. Evidence: weak to moderate.
- Apple Watch accuracy matters: against a chest strap, Apple Watch HRV (SDNN) had a mean absolute error of about 20 ms and did not meet equivalence, while resting HR was accurate (mean absolute error about 3.7 bpm) (Doherty et al. 2024, Series 9 and Ultra 2).
- **Rule:** never act on one HRV reading. Use a 7-day rolling average against a 60-day personal normal range; weight resting HR and sleep at least as heavily as HRV; require two signals to agree before downgrading a hard day. Readiness can move or soften a hard session; it never adds intensity.

### 3.5 Load guardrails

Evidence (full notes in `docs/research/spec-evidence.md`, and for pain stops and the return after them in `docs/research/pain-return-evidence.md`):
- **Weekly increases.** The only randomised trial of the 10% rule (GRONORUN, 532 novice runners) found no fewer injuries with a graded 10%-rule programme: 20.8% versus 20.3% injured [2]. A 2018 systematic review called the evidence on load changes and running injury "very limited" [5]. Cohort studies link harm only to much larger jumps: more than 30% a week in novices (a borderline result, for distance-related injuries) [3], and 20 to 60% in half-marathon trainees [4]. The Garmin-RUNSAFE cohort (5,205 runners, about 588,000 sessions) found no link between week-to-week change and injury [1]. Evidence for the 10% rule: weak.
- **Rolling ratios.** The acute-to-chronic workload ratio (ACWR) "sweet spot" of 0.8 to 1.3 is widely used, but its injury-prediction evidence is contested (Zouhal et al. 2021 editorial; Impellizzeri et al.), and Garmin-RUNSAFE found a negative dose-response for it [1], so a rolling cap has no support as an injury predictor. Evidence: weak.
- **Single-run spikes.** What did predict overuse injury in Garmin-RUNSAFE was a single run longer than the longest run of the previous 30 days: hazard rate ratio 1.64 for runs 10 to 30% longer, 1.52 for 30 to 100% and 2.28 for more than 100% [1]. The authors say even 1 to 10% increases may carry some risk and that the result needs confirming. It is one observational cohort (average age 46, 22% women), so treat it as the best current signal, not settled.

**Rules (heuristics, labeled as such).** Every number below is a heuristic default, not a measured threshold. Where a figure is coaching convention rather than injury evidence, the rule says so.

1. **Single-run spike rule (all plans; the primary load check).** No planned run is more than 10% longer, by distance or by time, than the longest run of the previous 30 days; the target is 5 to 10%. Both figures are heuristics derived from [1], which reports no target: 10% sits at the bottom of the band that raised injury rate, and the authors say even 1 to 10% increases may carry some risk, so the evidence on smaller increases is unclear.
2. **Weekly caps (convention, not injury evidence).** Weekly time or distance rises no more than about 10% week over week, kept as a conservative default; no more than 30% over any rolling 4 weeks, kept only as a sanity check. Neither is supported as an injury predictor [1][2][5]; they stay because they are cautious and widely used. Both checks measure each week's volume outside races (rule 3). During a return ramp (rule 4), the return after a pain stop of more than 14 days (rule 7) or a regrowth (rule 6), both checks measure against pre-break or pre-stop volume or the original plan instead of the reduced weeks, so the approved steps are not refused; the bound against the week actually run is then the ramp's or return's own steps, or rule 6's regrowth bound in regrowth weeks. How the weekly checks see a break is in rule 4.
3. **Race week.** The race itself is left out of the weekly caps of rule 2: out of race week's 10% check (the rest of race week still counts) and out of the baseline for the following week's check, so a race-inflated week never allows a bigger next week (owner's decision, #38). The rolling 4-week check leaves the race out the same way, in race week and in the windows after it, so a short taper that ends in a long race is not refused because of the race; that is a heuristic reading of the decision, which names the 10% check. The race still counts everywhere else a week's volume is counted (the recovery-week cadence, the volume freeze and the week the long-run share is read against), unchanged, the conservative reading. A half or full marathon is usually longer than any training run, so the spike rule (rule 1) runs on the race as an information-only flag, never a block [1]. Pfitzinger treats the race and the recovery after it as part of the plan, not as extra load to cap [9]. The days after a race are easy-only (easy runs or rest), scaled to race distance: at least 3 to 5 days after a half marathon and 7 to 14 after a marathon. Those day counts are coaching convention; the evidence check found no recovery-timing study it could read. No figure is set yet for shorter races.
4. **Return from a break** (consecutive days with no running).
   - 5 days off or fewer: resume the plan where it stands.
   - 6 to 14 days off: week 1 at about 60 to 70% of pre-break weekly volume with no hard sessions; week 2 at about 80 to 90% with one quality session; full volume in week 3. The first long run back must pass the spike rule (rule 1). During the ramp, the 10% weekly check and the rolling 4-week check (rule 2) measure against pre-break weekly volume, not the reduced weeks: the steps from about 65% to 85% to 100% are rises of roughly 30% and 18% over the week before, which the plain 10% check would refuse. The ramp steps, never above pre-break volume, are the bound.
   - **How the weekly checks see a break.** Rule 2's checks see Monday-start weeks, not days. There a break week holds at most 25% of the pre-break weekly volume outside races (pre-break volume: the mean of the 4 weeks before the break), with no race and a known volume. One or two break weeks in a row are a short break, the weekly reading of 6 to 14 days off: the next three weeks may hold at most 70%, 90% and 100% of the pre-break volume (the upper ends of the steps above), and weeks 2 and 3 also at most the ramp's own rise over the week before (about 29%, then 11%), so a runner who came back lower than the ramp isn't jumped to it. These caps take the place of the 10% check for those weeks; from week 4 back on, the plain rules apply. Week 1 back holds no quality session and no steady long-run finish, so it is all easy running and is left out of the 75 to 85% easy share (3.1); week 2 back holds at most one quality session. A race counts toward those limits as it does toward the weekly quality limit (owner's amendment on #62; the conservative reading, as a race is a hard effort). In the rolling 4-week check, short-break weeks among the 4 earlier weeks count at the pre-break volume, so the window that still holds the break doesn't refuse a return to the pre-break level: with history 240, 240, 240, 0, 0, 240, 240, 240 minutes, the next week's window is measured against 4 × 240 = 960 minutes rather than 480 (#38). Three or more break weeks in a row are a longer break: rules 1 and 2 as written. So are the weeks after a short break when a week of unknown volume (#40) lies within 7 weeks before it or between it and the week checked, since that week could hide a longer break; where it could instead hide a short break, the week is held to the least ramp cap and the least quality limit that break could set (the plan builder keeps under both; the checker reports the 10% check, or the quality limit, as not evaluated above them). Both are the conservative reading. Two further choices are deliberate: the pre-break mean keeps any recovery week among those 4 weeks, so it can sit a little below the build level a runner left from, and a race week counts in it only by its volume outside the race, as in rule 3. Every figure here is a heuristic: the 25% line, the 4-week mean, the 2-week limit, the 70/90/100% caps and the ramp's own rise. Two calendar weeks of little running can hold up to about 20 days off, so this weekly reading counts a few more days as a short break than the day count above does. The evidence is the same as for the ramp [6][9][10].
   - Paces after a break use the Daniels return factor: no change up to 5 days off, about 97% of pre-break VDOT after 2 weeks off without cross-training (97.3%; 98.6% with cross-training) [8]. Not built yet: plans after a break are paced from the current fitness anchor with no return factor (follow-up #93).
   - Longer than 14 days: normal progression under rules 1 and 2, not rule 6's regrowth.
   - After a pain stop (rule 7), rule 7's week 1 comes first; from week 2 on, the return takes whichever of this ramp and rule 6's regrowth gives the lower volume (after more than 14 days off, rule 7's own ceilings instead). Rule 7's guards apply on top and cancel this ramp's week-2 quality session.
   - Evidence: endurance athletes lose about 4 to 7% of VO2max after 12 to 15 days off [6], and short detraining quickly reduces VO2max and blood volume [7]. Pfitzinger resumes the schedule after fewer than 10 missed days [9], and the AIS says return time scales with the break, with no formula [10]. No study tests a specific return ramp, so the 60 to 70% and 80 to 90% steps are heuristics, and tendon and bone deconditioning are less studied than aerobic fitness. Because the 30-day window still holds pre-break runs, the spike rule alone can let a normal-length long run through in week 1; the reduced week's volume and the long-run share cap (rule 5) still bound it. The evidence file also suggested trimming the first long run back by the same fraction as the week; that was not adopted for breaks, so the spike rule and the share cap are the only long-run bounds during a break return. After a pain stop it is adopted (rule 7).
5. **Long run.** The spike rule (rule 1) is the main check. On top of it:
   - Time cap: about 150 minutes by default, up to about 180 minutes in marathon plans, and never more than the runner's own max session length (F2).
   - Share of the week: no more than about 30 to 35% of weekly time for 5K to half marathon plans. In marathon plans, a warning (shown, never a block) above 35% of weekly time and a hard ceiling at 45% (owner's decision, #38). A marathon plan here means the weeks up to and including the week of a race of marathon distance (within 0.5% of 42.195 km, the tolerance race names use; a race from 30 km up to that is planned with the usual share and the 150-minute default cap, #30); a race of unknown distance doesn't count as one, so the usual share applies (the conservative reading). How the plan builder uses the extra room is in F3.
   - Evidence: Daniels, as summarised by Hansons [11], keeps the long run under 25 to 30% of weekly mileage, capped at 2.5 to 3 hours, and Hansons calls 25 to 30% a "cardinal rule" with 2 to 3 hours as the useful window [11][13]. Mainstream novice marathon plans go to about 45 to 50%, so the sources disagree. No study tests a long-run share threshold; injury in [1] tracked how a run compared with recent runs, not its share of the week. The share and time figures are coaching consensus, not injury data. If the 45% ceiling binds week after week, the plan needs more weekly volume or a longer build rather than a bigger share.
6. **After a missed, cut or painful week** (including a pain freeze or stop, rule 7). Hard sessions become easy runs of the same length first; only then are runs trimmed. Missed runs are not made up [9]. The plan then grows back to the original plan, never above it (owner's decisions, #107).
   - **Cut week (heuristic).** A week counts as cut, and starts a regrowth, only when going straight back to the original plan the next week would break one of two limits: (a) the spike rule (rule 1), a run more than 10% longer than the longest run of the previous 30 days [1]; or (b) a week more than 20% above the volume actually run that week (outside races, as in rule 2). Otherwise the plain rules (rule 2) apply. Only the spike rule is a limit with direct injury evidence (one large cohort [1]). The 20% weekly rise rests on weak evidence, as in rule 2: Garmin-RUNSAFE found no link between week-to-week change and injury [1], the novice cohort's more-than-30% result is borderline [3], the half-marathon cohort found one association in the 20 to 60% band [4], and a systematic review called the evidence "very limited" [5]. 20% is the bottom of the band [4] links to harm; its value is a heuristic. No study defines a cut week.
   - **Regrowth (heuristic).** Each regrowth week may grow to the higher of (a) 20% over the previous week actually run and (b) the matching return step, 65%, then 82.5%, then 100% of the original plan, counted from the first week after the cut week. Nothing goes above the original plan, and every run passes the spike rule (so the first long run back doesn't jump to the next scheduled long run). The 20% is a default heuristic with weak evidence (see the cut week); the return steps are rule 7's, so no low week returns slower than the pain return's steps. In a flat plan, a cut to about 70% of plan or more is back at plan within 2 weeks, and any cut, a fully missed week included, within about 3 weeks; a rising build week, a long run held back by the spike rule or a recovery week can take longer. For regrowth weeks only, this bound takes the place of rule 2's 10% check against the week before; rule 2's 10% and rolling 4-week checks keep measuring against the original plan, not the cut weeks, as before. Regrowth keeps measuring against the original plan until a week is back at plan, including after a short-break ramp (rule 4) that ends below the original plan; the plain 10% check doesn't take over before then.
   - **Inside a regrowth (heuristic).** A regrowth week run at what it was planned to hold, at least 1/1.2 (about 83%) of that week's planned volume, continues the count: it is not a new cut week, though it sits below the original plan. A regrowth week run short of that is a new cut week (the cut-week test measured against that week's own planned bound rather than the original plan), and the count restarts at step 1 from the week actually run. The 83% is derived from the 20% default, not a separate figure.
   - **With a break or a pain stop.** A longer break (rule 4: more than 14 days off, or three or more break weeks in a row) is not a cut week: rule 4's "rules 1 and 2 as written" holds there, and this regrowth does not (its slow return is open: #111). After any short break (rule 4), not only after a pain stop, a week that is both in rule 4's ramp and in this regrowth takes the lower of the two, since both bounds apply. After a pain stop, rule 7's return guards apply on top (alternate-day first week, long-run cap, no quality sessions until a full symptom-free week at plan volume, step back on recurrence), and from week 2 on, when rule 4's ramp also applies, the lower of the two wins; after a stop of more than 14 days, rule 7's ceilings bound the weeks back instead.
   - Evidence: no study tests a specific rebuild ramp. Only the spike rule is a limit with direct injury evidence (one large cohort [1]); the 20% rise rests on weak evidence [3][4][5], and the return steps are coaching convention (Pfitzinger [9], AIS [10]). The owner chose the higher of the two over return steps only below 25% (a cliff) and 20% alone (about 8 weeks after a very low week, and never after a fully missed one, since 20% of 0 is 0); the options weighed are in `docs/research/spec-evidence.md`. The Run Clever trial (447 runners) found no difference in injury risk between progressing intensity and progressing volume [14], so cutting intensity before volume is a low-risk default rather than an evidence-backed one. The AIS recommends rebuilding load step by step, guided by how the athlete responds [10].
7. **Pain.** Every number in this rule is a heuristic. Nothing in it is a default for a particular runner.
   - **Usual pain** is the runner's own level for that spot: the median of their last 5 stable post-run check-ins (of all of them while there are only 3 or 4; a half-point median, such as 1.5 from 4 check-ins, rounds down, which makes the limits stricter), where a stable check-in is one taken while no pain stop, return or clinician flag is active. Until 3 stable check-ins exist, usual is the usual pain level the runner gave for that spot in the goal interview (F2), a runner-entered seed. Usual is 0 only for a runner with no pain history. During a stop, the return after it and while the clinician flag is on, usual stays frozen at its pre-stop value. All of this is heuristic, including that usual comes from post-run check-ins but is compared with next-morning and walking pain.
   - **Symptoms** means pain in that spot above usual, or any change in how the runner moves; **symptom-free** means neither.
   - **Pain check-in:** if the runner reports a recurring pain or injury area in the goal interview (F2), ask one question after every long run and every quality session: pain 0 to 10. A score of 4 or more, or a rise of 2 or more from the previous check-in, freezes volume growth for a week and swaps the next quality session for easy running. Runners who report no pain history aren't asked. (Whether this +2 should also count from usual is open: #84.)
   - **Pain stop rule:** any of these stops progression and drops the plan to easy-only or rest: pain that gets worse during a run, a change in how the runner moves, the next-morning trigger below, a red flag (see the clinician flag), or pain above usual on most days for about 7 days. It applies to pain reported by any runner, through the check-in or after any run. The app never diagnoses.
   - **Next-morning trigger.** Next-morning pain in that spot stops running if it is 2 or more above usual, 4/10 or more, or still above usual 48 hours after the run. A rise of 1 above usual, or a rise over successive weeks, doesn't stop running; it freezes volume growth for a week, as the check-in does. The question asks about one spot, so general muscle soreness doesn't count. The 4/10 limit matches the check-in's; the +2 matches the check-in's size of rise but counts from usual rather than from the previous check-in; the 48-hour limit follows [19].
   - **Which rule judges a run.** Inside a test run, in-run pain is judged only by the test-run limits; going past them fails the test, which keeps the stop on. During the return, symptoms on a run follow the recurrence rule (step back; a second failure at the same step reopens the stop). Outside those two, pain that gets worse during a run stops running. The next-morning trigger, a movement change and a red flag always stop at once, inside a test run or the return too.
   - **During a stop and the return**, the app asks each morning for pain in that spot and for pain on daily walking, so a stop can end without the runner having to volunteer reports.
   - **Ending a stop.** The plan stays at rest or easy-only until all three of these hold:
     - 2 mornings in a row at or below usual pain: the 2 mornings just before the test run. A morning above usual restarts the count.
     - Pain on daily walking at 2/10 or less [17].
     - One passed test run: easy and flat, 20 to 30 minutes or half a usual easy run. Pain during it stays at usual +1 at most and at 3/10 at most, movement doesn't change, and the next morning is at or below usual. If the stop came from a movement change, pain must stay at or below usual for the whole test run.

     A failed test restarts the 2-morning count, so a stop lasts at least about 3 days. When all three hold, the stop is cleared and the return starts. If usual is 4 or more, or pain on daily walking stays at 3 or more, the stop can't end this way: the runner stays stopped and the clinician flag turns on. Usual of 4 or more is judged at the start of the stop; walking pain of 3 or more is judged about 7 days into the stop, matching the 7-day trigger (both heuristic timings). In the same way, a runner with no pain history has usual 0, so a new pain that sits above 0 keeps them stopped, with the clinician flag on, until it returns to 0. A way to re-baseline, for example after a clinician has seen the new pain, is an open question (#85).
   - **Return after a stop.**
     - Week 1: easy runs on alternate days [18]. On week-1 runs, pain up to usual +1 and at 3/10 at most is allowed, matching the test run's limit (heuristic); more than that, or any movement change, counts as symptoms coming back. The long run is capped at the week's ramp fraction of the pre-stop long run (about 65%, rule 4's week-1 step). The 65% applies even after a short stop (5 days off or fewer), where rule 4 itself has no ramp; that is a conservative heuristic. The spike rule (rule 1) alone doesn't bind here, because its 30-day window still holds the pre-stop runs.
     - From week 2 on: the lower of rule 6's regrowth and, when the runner took 6 to 14 days off, rule 4's ramp. After more than 14 days off, the weeks back are bounded by the return's own ceilings, at most 65%, 82.5% and 100% of the pre-stop level in weeks 1, 2 and 3, plus the spike rule (rule 1), not by rule 2's checks or rule 6's 20% bound measured from the stop weeks, which would keep the runner near the 20-minute test run indefinitely (owner's decision, #107; the ceilings are heuristics). The other guards here still apply. Known consequence: a stop of more than 14 days can reach 100% a week sooner than a 6 to 14 day stop, whose rule 4 ramp caps week 3 at about 11% over week 2.
     - No quality sessions until 1 full week at plan volume with no symptoms. Distance comes back before speed [18]. This cancels rule 4's week-2 quality session.
     - Recurrence: if symptoms come back on a run, the run ends, the next day is rest and the plan goes back one step [20]. In week 1, going back a step means repeating week 1. Later, it means the previous week of the rule in force: the previous rule 6 or rule 4 step, or, after more than 14 days off, the previous of those ceilings. A second failure at the same step reopens the stop and turns the clinician flag on. A movement change reopens the stop at once (see which rule judges a run).
   - **Clinician flag.** The app advises seeing a clinician when pain above usual lasts on most days for about 7 days [22]. It advises it at once on a red flag: swelling, can't bear weight, or numbness or tingling [23]; and sharp pain or a lasting change in how the runner moves (product heuristics, not from [23]). Every raise of the flag (about 7 days above usual, a red flag, a second failure at the same return step, a runner who stays stopped, or a reopen) also starts a pain stop or reopens one, so the stop's normal end path applies.
     - It turns off only after 3 reports in a row at or below usual, at least 1 of them a passed test run. A passed test run counts as a report at or below usual. Silence never clears it. Ending the stop always meets this (2 mornings at or below usual, then the passed test run), so the flag clears when the stop ends; a runner who can't end the stop (usual 4 or more, or walking pain staying at 3 or more) keeps the flag on while reports continue; if reports stop, the 14-day close applies.
     - With no reports, the app asks once at 7 days and closes the stretch as unresolved (advice given) at 14 days. The close never ends a stop: the stop and the return rules stay in force.
     - A new stop trigger in the same spot within 6 weeks of the flag turning off or closing reopens the stretch with the flag on.
   - Evidence: in Achilles tendinopathy, continued running guided by pain monitoring did no harm compared with rest [15], so mild, stable pain alone does not stop running. That model, as Silbernagel teaches it, allows pain up to 5/10 during activity, after it and the next morning, as long as pain and stiffness don't rise week to week [21]; the return-to-sport consensus gives the same 5/10 limit, with pain that "should subside by the next morning" [16]. Neither [15] nor any other source read says next-morning pain must be "no worse than before the run"; that phrase is a paraphrase and is not attributed to [15]. The 5/10 limits were tested in diagnosed tendinopathy under supervision, bone stress needs pain-free running, and the app can't tell which tissue hurts, so the triggers here are stricter: a 4/10 limit and a 2-point rise above usual, in line with the check-in, plus the 48-hour limit. The consensus calls for a graded, criterion-based return and notes that most return-to-sport criteria lack solid evidence [16]; return-to-run studies after bone stress injury require 2 to 28 days of pain-free walking, often start on alternate days and bring distance back before speed [18]; an NHS leaflet advises running only once 30 minutes of walking is symptom-free or nearly so [19]; and a graded bone-stress programme progresses only when the runner is symptom-free during the run, after it and the next day, dropping back a stage after a rest day if symptoms return [20]. The NHS advises seeing a GP or physio for knee pain that lasts a week and Achilles pain after 2 to 3 weeks [22], and urgent help for inability to bear weight, growing swelling, or numbness or tingling [23]; one clinician advises help if pain persists after two weeks [24]. No study tests return rules for runners whose injury is unknown, and no source sets an off rule for the clinician flag, so the 2-morning count, the test-run length and the +1 margin are conventions, and the 3 reports, 7 and 14 days, 6 weeks, the median of the last 5 check-ins, the interview seed for usual, the frozen usual level, about 7 days above usual starting a stop (a new product decision), the two extra red flags, the usual +1 allowance on week-1 return runs, rounding a half-point median down, when a runner counts as staying stopped, and the 65% cap after short stops are product heuristics. Evidence: weak.

Also (heuristics, coaching convention, not reviewed in depth): a recovery week every third or fourth week, and at most two quality sessions a week.

### 3.6 Hills (grade-adjusted pace)
- Strava's current GAP model was fitted from heart rate across about 6 million runs: efficiency (HR per unit speed) as a function of gradient. Its downhill benefit bottoms out around -9% (pace factor 0.88) and returns to flat by about -18%.
- **Rule:** use a GAP curve as the default and personalize it from the athlete's own HR-versus-grade data once there are enough steady hilly runs. Targets on hilly routes are set in grade-adjusted pace.

### 3.7 Heat and humidity
- Across 1.8 million marathon finishes, performance follows a quadratic curve with temperature; the best temperature is about 3.8 to 9.9°C depending on ability, and pace falls off increasingly as it gets warmer (El Helou et al. 2012). Heat also changes pacing more for faster runners (Ely et al. 2008).
- **Rule:** heart-rate-governed easy runs need no heat math; HR already rises in heat. For pace-targeted sessions, start with a temperature-plus-dew-point adjustment table and replace it with a personal model fitted from the athlete's pace-at-HR versus weather history. The app shows both the raw and adjusted target so the athlete can see why.

### 3.8 Treadmill
- A 1% treadmill grade best matched the energy cost of outdoor running at 2.92 to 5.0 m/s (about 9:11 to 5:22 per mile) (Jones & Doust 1996). Easy paces slower than that are an extrapolation.
- **Rule:** treadmill sessions default to 1% incline and use HR as the primary target. Learn the athlete's treadmill offset (pace at the same HR, treadmill versus outdoor) from the runner's treadmill history, and apply it to treadmill targets.

### 3.9 Race-time prediction
- Riegel's formula (T2 = T1 x (D2/D1)^1.07) was well calibrated up to the half marathon in 2,303 recreational runners but predicted marathons at least 10 minutes too fast for half of them (Vickers & Vertosick 2016).
- **Rule:** show a blended prediction: Riegel from recent races and best efforts (half marathon and shorter), a critical-speed estimate from best efforts across distances, and a threshold-based estimate (pace at LTHR). For marathons, apply the Vickers-Vertosick correction or a volume-based model. Show the range, not one number.

## 4. Features and acceptance criteria

IDs are stable so Claude Code can reference them in issues and tests.

### F1. History import and baseline
- Imports all runs and health data (section 5), de-duplicates same-time activities (keep the one with the richest streams), and tags treadmill runs.
- Produces a baseline report: current weekly load, long-run history, PRs and best efforts, estimated LTHR and max HR, current zones, easy pace at a fixed HR, typical decoupling, cadence trend, resting HR and HRV baselines.
- **Accept when:** on a synthetic fixture history with planted duplicates and a cadence gap, the importer leaves no duplicate pairs, flags the gap, and produces an LTHR estimate with the evidence runs listed. Every baseline value comes from the data; none is a default for a particular person.

### F2. Goal interview
- After the baseline, asks only what the data can't answer: goal race, date, goal time (or "best possible"), days available, long-run day, max session length, treadmill access, pain history (for each recurring pain or injury area: where it is, and its usual pain on a normal day, 0 to 10, which seeds usual pain in 3.5 rule 7). One question at a time; skips anything already known. Race name, date, distance and time goal (or "best possible") are always set by the athlete, never hard-coded, and can be edited anytime in Settings; any change re-plans the remaining weeks from today.
- **Accept when:** the interview takes under 3 minutes, never asks something the baseline already shows, and a goal edit produces a re-planned, guardrail-checked plan with the changes explained.

### F3. Plan builder
- Builds a periodized plan (base, build, peak, taper) for 5K to marathon from the baseline, goal and section 3 rules.
- Each workout has a purpose, a target in HR and grade-adjusted pace (or power), duration, and the rule that produced it.
- Long runs are placed within the single-run spike rule and the long-run time and share caps (3.5 rules 1 and 5); the time cap never exceeds the runner's max session length from F2. In marathon plans the long run may take more than the usual share of the week, up to the 45% ceiling with a small margin, but only to bring it up toward about 150 minutes, rule 5's default time cap (heuristic). It still grows at most 10 minutes a week, and it gives back that extra time before it would leave an easy run under the easy-run floor. So a low-volume marathon plan gets longer long runs with the rule 5 warning shown, and a higher-volume one keeps the usual share.
- The race needs no room under the weekly caps (3.5 rule 3), so the taper's length is a plan heuristic, not something the guardrails force.
- **Provisional plans.** A plan built after its start week has begun (mid-week, or on a Monday after noon or after a run that day) is provisional: it is sized to keep 3.5 however that open week ends, which holds its first weeks back. The app rebuilds it from a fresh baseline as of 00:00 on the plan's first Monday, when the start week is closed history, whenever it next runs on or after that moment (or as of the latest Monday, if a whole week or more passed without a rebuild). When a rebuild is refused, the provisional plan stays in place (it already passes 3.5), its note says so, and the rebuild is tried again from the next Monday, or from a later date the refusal names; each refused retry sets the next one. No retry is set once the next try would fall in the race week, and the provisional plan then runs to the race. A refusal that only a bug in the app's wiring can cause (the baseline not built as of the rebuild's start day) is kept and retried the same way, and the app also logs it so it isn't missed. A provisional plan's own note (which names its rebuild day) is always the last of the plan's notes, so the app can show the refusal's note in its place. Keeping the plan and retrying weekly is a product default, not a research finding (#55).
- **Accept when:** every generated plan passes the guardrail checker (3.5), including the single-run spike rule, in tests, and easy-run share stays within 75 to 85% of time (except week 1 back after a short break, which is all easy, 3.5 rule 4).

### F4. Automatic adaptation
- After each run, compares what was done with what was planned, using pace together with HR relative to zones, decoupling, cadence fade (cadence drop in the final third versus the first third), power-to-HR, and RPE if given.
- Interprets context: beating pace at a low HR means fitness is ahead of the plan; hitting pace at a high HR means it is not.
- Missed days: redistributes the week without cramming (drop the lowest-value session first, never stack two quality days).
- Missed or cut weeks, breaks and pain follow 3.5 rules 4, 6 and 7: easy before trimming, a stepped return after 6 to 14 days off, growth back to the plan by the higher of a 20% weekly rise and the return steps, within the spike rule, but never above it, and a stop on worsening or lasting pain.
- Missed targets: two or more sessions missed in the same direction move the paces; one-offs do not.
- Volume and difficulty change only through this engine, inside the guardrails.
- **Accept when:** replaying fixture runs through the engine produces sensible, explained changes, and each change cites its trigger metrics.

### F5. Daily readiness check
- Each morning combines HRV trend, resting HR versus baseline, sleep duration and the last pain check-in (if the runner tracks one) into green, amber or red.
- Amber softens the hard session (shorter or lower intensity); red moves it or makes the day easy. Never adds intensity.
- **Accept when:** a single low HRV reading alone never changes the plan.

### F6. Post-run debrief
- Within a minute of a run syncing: three to five plain lines on what pace, HR, drift and cadence say, and what changes this week because of it.
- **Accept when:** every claim in the debrief maps to a computed metric (no free-form guesses).

### F7. Hill-adjusted targets and course prep
- Targets in grade-adjusted pace on hilly routes.
- Imports a race course (GPX), finds its climbs, and adds course-specific sessions in the build phase (hill repeats matching the race's longest climb, long runs on similar terrain).

### F8. Weather and treadmill adaptation
- Pulls a forecast for the planned run time and adjusts pace targets per 3.7; shows raw and adjusted.
- Treadmill mode per 3.8.

### F9. Load guardrails
- Section 3.5, enforced as a checker over every plan change: the single-run spike rule, the weekly caps, race-week handling, the return-from-break ramp and the long-run limits, plus pain check-ins after long runs and quality sessions for runners who report a pain history and the pain stop rule for any runner.
- Warnings and information flags (the race as a spike, a marathon long run above 35% of the week) are shown with their reason but never block a plan.

### F10. Watch sync
- Phase 1: sends the next two weeks of workouts to the native Apple Watch Workout app with WorkoutKit (custom workouts with HR, cadence, power and speed alerts).
- Phase 2: the app's own watch app runs the workout (F11).

### F11. Live voice coach (a headline feature)
- Spoken cues to speed up or slow down, through AirPods (or the phone speaker), more accurate than Runna's.
- Accuracy design:
  - Pace from a smoothed estimate that blends GPS speed with the watch's running-speed and step data (Kalman filter or similar), not instantaneous GPS.
  - Targets in grade-adjusted pace, so a climb does not trigger "speed up".
  - HR ceiling on easy runs: if HR is above the cap, cue "ease off" even when pace is on target.
  - Cue only on sustained deviation (for example 20 to 30 seconds outside the band), with hysteresis and a minimum gap between cues; never in the first 60 seconds of a rep.
  - Rep countdowns, rep splits, and a short summary at each interval end.
- **Accept when:** replaying simulated recordings (synthetic streams with GPS noise, hills and pace changes) through the cue engine gives no more than one false "speed up" per hilly mile, and the cue engine's pace estimate tracks lap-average pace within 5 sec/mile.

### F12. Race-day plan
- Mile-by-mile pacing from the predicted time, adjusted for the course profile and forecast, plus a fueling and fluid plan by time. Fed straight to the voice coach.

### F13. Progress dashboard (core of motivation)
- Leads with the numbers that move first. Each card shows the current value, a trend line, and the change over 4 and 12 weeks; improvements are highlighted, and flat periods are explained honestly.
- Metrics:
  - Easy pace at a fixed heart rate (the heart rate is set from the runner's own zones).
  - Heart-rate drift (decoupling) on long runs.
  - Predicted race times, recalculated weekly.
  - Resting HR and HRV trends (7-day average against normal range).
  - Best efforts: mile, 5K, 10K, 10 mile, half.
  - Weekly load versus plan, and easy-intensity share.
  - Cadence trend (when cadence is recorded).
- **Accept when:** the dashboard can show at least one improving metric for any 4-week window in which training happened, or says plainly that nothing moved and why.

### Units setting
- The runner chooses metric (km, min/km, metres of climb) or imperial (miles, min/mi, feet of climb) in Settings. The default comes from the device's measurement system: US locales get imperial, everyone else metric. Changing it re-words text only; it never changes a target, a limit or a plan decision.
- CoachCore computes in SI units (seconds, metres, seconds per km). Every user-facing distance, pace and climb (debrief, progress summary, plan and goal text, adaptation details) goes through one formatter, which converts before rounding (1 mi = 1609.344 m, 1 ft = 0.3048 m exactly). The F6 contract holds in both units: shown numbers are the formatter applied to the facts, and every stated comparison holds on the numbers shown in the runner's unit.

## 5. Data sources

| Source | What it gives | How | Notes |
|---|---|---|---|
| Apple HealthKit (primary) | Workouts with routes; HR; running power, speed, stride length, ground contact, vertical oscillation; steps (cadence); HRV (SDNN), resting HR, HR recovery, VO2max estimate, sleep, respiratory rate | Native iOS app | Needs an iPhone app with HealthKit permission; no web access to HealthKit. |
| Strava API (optional) | Activities and streams (HR, cadence, altitude, velocity, grade, power), best efforts | OAuth, webhooks | See 5.1 on terms. Useful only for runs not in Apple Health. |
| Weather | Hourly forecast and historical weather | WeatherKit or Open-Meteo | Activities usually carry no weather. |
| Race courses | Elevation profile | GPX import | |
| Runner input | Goal, availability, RPE, pain score (if tracked), pain reports after a run (3.5 rule 7) | In-app | |

### 5.1 Strava terms (decision needed)
- Strava's November 2024 API agreement bars third parties from using data obtained through its API in AI models, and Strava's statement focused on model training; reporters read the terms as broader. In 2026 Strava also began requiring standard-tier developers to hold a Strava subscription.
- Sending Strava API data to an LLM for debriefs could fall inside that restriction. **Recommendation:** make Apple Health the source of truth for runs (the watch records them there anyway), keep Strava optional for backfill and comparison, and send only computed summaries, not raw Strava data, to the LLM. This is a reading of public reporting, not legal advice.

## 6. Platform recommendation

**Native iPhone and Apple Watch app (SwiftUI), local-first.**

- HealthKit (HRV, resting HR, sleep) is only reachable from a native iOS app.
- Custom live voice cues need the app's own watch workout (HKWorkoutSession with a live workout builder, workout-processing and audio background modes) or an iPhone workout session (supported on iOS from WWDC25, with a Bluetooth HR strap for HR). WorkoutKit alerts in the native Workout app cover heart rate, cadence, power and speed ranges, but they are Apple's alerts, not custom spoken coaching.
- Tradeoff: a native app is more work than a web app and needs macOS to compile, which section 6.1 solves with cloud build machines. A web dashboard alone could not read Apple Health or coach live.
- Garmin alternative: for runners on Garmin, a Connect IQ app could run workouts, but spoken cues are far more limited there. Apple Watch is the better fit for the voice coach.

### 6.1 Building and installing without a Mac

The owner builds from a Windows PC with no Mac, so every build runs on a macOS machine in the cloud and reaches the iPhone and watch through TestFlight.

**Recommendation: GitHub Actions macOS runners, fastlane and TestFlight.**

- Claude Code writes the code and pushes to GitHub. A workflow on a GitHub-hosted macOS runner builds the iPhone app with its embedded watch app, signs it and uploads it to TestFlight. The owner installs it from the TestFlight app on their iPhone, and the watch app installs on the paired watch.
- Nobody opens Xcode: the project file is generated from a text spec (XcodeGen), and signing runs through fastlane match (certificates in a private, encrypted repo) with an App Store Connect API key. A solo developer reports shipping five iOS apps this way from Windows with Claude Code, about 12 minutes from push to TestFlight.
- CoachCore tests run on cheap Linux runners on pull requests that are ready for review and change more than docs (see CLAUDE.md for the exact rules, which keep within the free plan's monthly minutes). The macOS build runs only on `v*` release tags or by hand.
- Cost: GitHub's macOS runner is $0.062 a minute. GitHub Free includes $12 a month of compute in private repos, about 190 macOS minutes or 15 to 19 builds. Past that, a build costs roughly $0.75. Expect about $0 to $25 a month while actively building, plus the $99 a year Apple Developer Program.
- Tradeoff: no iOS Simulator or Xcode debugger at hand. Debugging leans on CoachCore unit tests (most of the logic), UI and snapshot tests on the macOS runner, a log export from the app, and the replay harness. The watch workout has to be tested on real runs anyway.
- Fallback for a hard bug: rent a cloud Mac with remote desktop for a day (Scaleway lists an M4 Mac mini at €0.22 an hour; providers often bill a minimum period).

| Option | Watch app, HealthKit, live audio? | Cost | Verdict |
|---|---|---|---|
| GitHub Actions macOS + fastlane + TestFlight | Yes, full Xcode toolchain | About $0 to $25 a month, plus $99 a year | Recommended |
| Xcode Cloud | Yes | 25 compute hours a month included with the developer program; 100 hours for $49.99 a month | The first workflow must be set up in Xcode on a Mac, so it needs a borrowed or rented Mac once |
| Rented cloud Mac (remote desktop) | Yes, full Xcode | Scaleway M4: €0.22 an hour or €149 a month | Fallback for debugging, not the daily loop |
| React Native, Flutter or Expo | iPhone side only; the watch app must still be native Swift, and these frameworks don't cover a watch workout session with spoken cues | Still needs macOS cloud builds | Rejected: adds a second language without removing the Mac build |
| Buy a Mac mini | Yes | One-time hardware cost | Simplest loop; not needed to start |

## 7. Architecture

```
iPhone app (SwiftUI)
  ├─ HealthKit importer ── de-dup, stream extraction
  ├─ Strava importer (optional)
  ├─ Weather client
  ├─ CoachCore (pure Swift package, no Apple frameworks)
  │    ├─ Metrics: zones, LTHR, GAP, decoupling, cadence fade, load
  │    ├─ Predictor: Riegel, critical speed, threshold-based
  │    ├─ Planner: periodization, workout library, guardrail checker
  │    ├─ Adapter: post-run and daily readiness rules
  │    └─ CueEngine: pace smoothing, hysteresis, cue decisions
  ├─ Store: SwiftData (local, on device)
  ├─ Dashboard: Swift Charts
  ├─ LLM layer: goal interview and debrief wording via the Anthropic API
  └─ WorkoutKit scheduler (Phase 1 watch sync)
Apple Watch app (Phase 2)
  └─ HKWorkoutSession + live builder → CueEngine → spoken cues (AVSpeechSynthesizer)
```

Design rules:
- All training decisions are deterministic code in CoachCore with unit tests. The LLM only interviews, explains and words the debrief; it never sets paces or volume.
- CoachCore is a plain Swift package so it builds and tests on Linux (Claude Code in the cloud can work on it) as well as macOS. The app targets build on GitHub Actions macOS runners (section 6.1).
- Nothing user-specific is hard-coded: zones, thresholds, paces, baselines and goals are computed from the runner's data or entered by the runner.
- Health data stays on the device. Only small computed summaries go to the LLM, and the API key lives in the Keychain.
- A replay harness feeds recorded-style runs through the Adapter and CueEngine: synthetic or simulated streams in CI, and optionally the runner's own exports from `Fixtures/local/` on their machine (never committed; Strava exports stay out of any LLM path per 5.1).

## 8. Adaptation algorithm sketch

```
after each run:
  m = metrics(run)            # pace, GAP, HR vs zones, decoupling, cadence fade, power/HR, weather, RPE
  e = expected(workout, zones, weather, grade)
  signal = classify(m, e)     # ahead, on_track, behind, overreached
  history.append(signal)

  # pain: 3.5 rule 7 decides; usual = the runner's own level for that spot, frozen during a stop, return or flag
  if a red flag or a change in how the runner moved:
      start (or reopen) a pain stop: easy-only or rest
  elif this was a test run: pass or fail it against the test-run limits only
  elif in the return and symptoms came back: end the run, rest a day, back one step
      (second failure at the same step: reopen the stop, clinician flag on)
  elif pain got worse during the run: start a pain stop
  elif runner tracks pain and (pain_score >= 4 or pain_score rose by >= 2):
      freeze volume 1 week; next quality -> easy
  if two of the last three quality sessions are "ahead" with HR at or below expected:
      move pace targets faster by one step (about 1 to 2%)
  if two of the last three are "behind" or "overreached":
      move pace targets slower one step; hold volume
  if easy runs average above the zone-2 cap:
      lower easy pace targets, flag in debrief
  if long-run decoupling < 5% at target duration twice
     (a long run with 40 min or less of moving time counts when finished with main-part average HR below the zone-2 cap, 3.3):
      allow next long-run step
  recompute zones after races, field tests, or every 4 weeks
  replan the rest of the week; run guardrail checker; explain every change

each morning:
  r = readiness(hrv_7d vs 60d range, rhr vs baseline, sleep, last pain check-in if tracked)
  green: as planned | amber: soften | red: move or easy
  (needs two agreeing signals to downgrade)
  next-morning pain (3.5 rule 7): >= usual + 2, >= 4/10, or above usual 48 h after the run -> pain stop
                                  usual + 1, or rising over weeks -> freeze volume growth 1 week
  pain above usual on most days for ~7 days, or a red flag reported this morning -> pain stop, clinician flag on
  during a stop or the return: ask for pain and pain on daily walking
  end a stop only by 3.5 rule 7 (2 mornings at or below usual, walking <= 2/10, a passed test run)
  clinician flag by 3.5 rule 7: every raise also starts or reopens a stop; off only after 3 reports at or below usual
      with a passed test run (a passed test run counts as one); never diagnose

missed day:
  drop the lowest-value session; never stack quality days; keep the long run if possible

missed, cut or painful week (3.5 rule 6):
  quality -> easy runs of the same length first, then trim
  cut week = going straight back to plan next week would break the 30-day spike rule
             or rise > 20% over the week actually run (heuristic)
  regrowth week k (k = 1, 2, 3 after the cut) <= max(1.2 x the week actually run, 65 / 82.5 / 100% of plan)
    never above plan; every run passes the spike rule; back at plan within ~3 weeks in a flat plan
  inside a regrowth: a week run at >= 1/1.2 (~83%, derived from the 20% default) of its own planned volume
    continues the count; a week run below that is a new cut week: restart at step 1 from the week run
  keep measuring against the original plan until a week is back at plan (also after a rule-4 ramp)
  during regrowth, 10% weekly and rolling 4-week checks measure against the original plan
  first long run back must pass the 30-day spike rule

break (3.5 rule 4):
  <= 5 days: resume the plan
  6 to 14 days: week 1 ~60-70% of pre-break volume, no hard sessions;
                week 2 ~80-90%, one quality session; week 3 full
                paces x Daniels return factor (~97% VDOT after 2 weeks off)
                during the ramp, 10% weekly and rolling 4-week checks measure against pre-break volume
                first long run back must pass the 30-day spike rule
  > 14 days: normal progression
              (after a pain stop: <= 65 / 82.5 / 100% of pre-stop volume + spike rule, 3.5 rule 7)

race (3.5 rule 3):
  race left out of race week's 10% check and next week's baseline; spike flag only
  easy-only days after: >= 3-5 after a half, 7-14 after a marathon
```

## 9. Roadmap

### Phase 0: Build pipeline

- Create the GitHub repo. Set up the XcodeGen project with iPhone and watch targets and the HealthKit capability, the CoachCore package with Linux CI, fastlane match with an App Store Connect API key, and a TestFlight upload of a first placeholder build.
- Owner's steps: enroll in the Apple Developer Program, create an App Store Connect API key and save it as GitHub secrets, and install TestFlight on the iPhone.
- Exit: a build pushed from Windows lands on an iPhone and watch through TestFlight.

### Phase 1: MVP (the plan engine and proof of progress)
- F1 history import and baseline (HealthKit), F2 goal interview, F3 plan builder, F4 adaptation, F9 guardrails, F6 debrief, F13 dashboard v1, F10 watch sync via WorkoutKit.
- Exit: a runner runs two weeks on the app's plan, workouts appear on their watch, and the dashboard shows baseline numbers computed from their own data.

### Phase 2: Live voice coach and readiness
- Watch app with HKWorkoutSession and the CueEngine (F11), daily readiness (F5), weather and treadmill adaptation (F8), hill-adjusted targets (F7 part 1).

### Phase 3: Race execution
- Course import and course-specific sessions (F7 part 2), race-day plan (F12), better predictions with a personal heat model and personal GAP curve.

## 10. Open questions

None open. The goal race, date, distance and time goal are set and edited in the app (F2).

Training-load decisions (Nov 21): the owner approved the research-amended guardrails in 3.5 (spike rule, weekly caps as convention, race week, return from a break, long-run limits, missed or painful weeks, pain stop rule). The evidence check is in `docs/research/spec-evidence.md`.

Pain stop decisions (Nov 21): the owner approved the four research-backed pain rules in 3.5 rule 7 (when a stop ends, the return after it, the next-morning trigger against usual pain, and when the clinician flag switches off). The evidence check is in `docs/research/pain-return-evidence.md`.

Regrowth decisions (Nov 21): the owner decided what counts as a cut week (going straight back to plan would break the spike rule or a 20% weekly rise), how the plan grows back (the higher of 20% over the week run and the return steps of 65 / 82.5 / 100% of plan, never above plan, within the spike rule, measured against the original plan until a week is back at plan) and how the weeks after a pain stop of more than 14 days are bounded (the return's own ceilings plus the spike rule) in 3.5 rules 6 and 7 (#107). The evidence check is in `docs/research/spec-evidence.md`, "Regrowth after a cut week".

Build decisions (Nov 20): target iOS 17 and watchOS 10 or later, voice cues through AirPods or the phone speaker, builds from Windows on cloud Mac runners, and an Apple Developer Program membership for TestFlight.

Other decisions the build can make by default: Apple Health as the source of truth (5.1), Phase 2 for the voice coach, SwiftData local storage.

## 11. Sources
- Oliveira, Boppre and Fonseca (2024), polarized versus other intensity distributions, Sports Medicine: https://link.springer.com/article/10.1007/s40279-024-02034-z
- Granero-Gallegos et al. (2020), HRV-based training and VO2max meta-analysis: https://pmc.ncbi.nlm.nih.gov/articles/PMC7663087/
- Doherty et al. (2024), Apple Watch Series 9 and Ultra 2 HRV and resting HR validity: https://pmc.ncbi.nlm.nih.gov/articles/PMC11478500/
- Zouhal et al. (2021), ACWR editorial, Frontiers in Physiology: https://pmc.ncbi.nlm.nih.gov/articles/PMC8138569/
- Friel, aerobic decoupling: https://www.trainingpeaks.com/learn/articles/aerobic-endurance-and-decoupling/
- Strava Engineering, an improved GAP model: https://medium.com/strava-engineering/an-improved-gap-model-8b07ae8886c3
- El Helou et al. (2012), environmental parameters and marathon performance: https://pmc.ncbi.nlm.nih.gov/articles/PMC3359364/
- Ely et al. (2008), heat stress and marathon pacing by ability: https://coachsci.sdsu.edu/csa/vol145/ely.htm
- Jones and Doust (1996), 1% treadmill grade: https://read.qxmd.com/read/8887211/a-1-treadmill-grade-most-accurately-reflects-the-energetic-cost-of-outdoor-running
- Vickers and Vertosick (2016), race times in recreational runners: https://pmc.ncbi.nlm.nih.gov/articles/PMC5000509/
- Apple WorkoutKit: https://developer.apple.com/documentation/workoutkit
- Apple WorkoutAlert: https://developer.apple.com/documentation/workoutkit/workoutalert
- Apple HealthKit, running workout sessions: https://developer.apple.com/documentation/healthkit/running-workout-sessions
- Apple WWDC25, track workouts with HealthKit on iOS and iPadOS: https://developer.apple.com/videos/play/wwdc2025/322
- DC Rainmaker on Strava's November 2024 API changes: https://www.dcrainmaker.com/2024/11/stravas-changes-to-kill-off-apps.html
- the5krunner, Strava's clarification: https://the5krunner.com/2024/11/20/strava-issues-clarification/
- TechRepublic on Strava's 2026 API tightening: https://www.techrepublic.com/article/news-strava-api-scraping-crackdown/
- GitHub Actions runner pricing: https://docs.github.com/en/billing/reference/actions-runner-pricing
- GitHub Actions included usage: https://docs.github.com/en/billing/concepts/product-billing/github-actions
- Apple Xcode Cloud, get started and pricing: https://developer.apple.com/xcode-cloud/get-started/
- Scaleway Apple silicon pricing: https://www.scaleway.com/en/pricing/apple-silicon
- Shipping iOS apps from Windows with Claude Code, fastlane and GitHub Actions: https://dev.to/snake_sun/how-i-shipped-5-ios-apps-in-30-days-as-a-solo-dev-claude-code-fastlane-asc-api-31kd
- Xcode Cloud from Windows, one-time Mac setup: https://dev.to/shovan/build-ios-app-on-windows-xcode-cloud-2h09

## 12. References

Numbered citations in sections 3.3 and 3.5. References 1 to 15 match `docs/research/spec-evidence.md` (which also lists 20), 15 to 24 match `docs/research/pain-return-evidence.md` and 25 to 30 match `docs/research/short-long-run-progression.md`; those files record what each source was read for. Reference 12 (units) is listed there and not yet cited here, and references 26, 27 and 30 are listed as background and not cited here. A description in square brackets stands in for a title that was not recorded when the source was read.

1. Frandsen JSB, Hulme A, Parner ET, … Nielsen RO. How much running is too much? Identifying high-risk running sessions in a 5200-person cohort study. *BJSM* 2025;59(17):1203–1210. doi:10.1136/bjsports-2024-109380. https://pure.au.dk/portal/en/publications/how-much-running-is-too-much-identifying-high-risk-running-sessio/ ; BJSM blog summary: https://blogs.bmj.com/bjsm/?p=11751
2. Buist I, et al. No effect of a graded training program on the number of running-related injuries in novice runners: an RCT. *Am J Sports Med* 2008;36(1):33–39. https://research.rug.nl/en/publications/no-effect-of-a-graded-training-program-on-the-number-of-running-r/
3. Nielsen RØ, et al. Excessive progression in weekly running distance and risk of running-related injuries. *JOSPT* 2014;44(10):739–747. https://vbn.aau.dk/da/publications/excessive-progression-in-weekly-running-distance-and-risk-of-runn
4. Damsted C, et al. The association between changes in weekly running distance and running-related injury: preparing for a half marathon. *JOSPT* 2019;49(4):230–238. https://researchportal.lih.lu/en/publications/the-association-between-changes-in-weekly-running-distance-and-ru/
5. Damsted C, Glad S, Nielsen RO, Sørensen H, Malisoux L. Is there evidence for an association between changes in training load and running-related injuries? A systematic review. *IJSPT* 2018;13(6):931–942. Europe PMC record: https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=EXT_ID:30534459%20AND%20SRC:MED&resultType=core&format=json
6. Barbieri A, et al. Cardiorespiratory and metabolic consequences of detraining in endurance athletes. *Front Physiol* 2024;14:1334766. https://www.frontiersin.org/articles/10.3389/fphys.2023.1334766/full
7. Mujika I, Padilla S. Detraining: loss of training-induced physiological and performance adaptations. Part I. *Sports Med* 2000;30(2):79–87. https://pubmed.ncbi.nlm.nih.gov/10966148/
8. VDOT O2 (Daniels). VDOT adjustments for time off from running (2018). https://news.vdoto2.com/?p=1285
9. Pfitzinger P, Douglas S. *Advanced Marathoning*, 4th ed., excerpt: What to do when your marathon training gets interrupted. Human Kinetics. https://us.humankinetics.com/blogs/excerpt/what-to-do-when-your-marathon-training-gets-interrupted
10. Australian Institute of Sport. Training load in relation to loading and unloading phases of training, v2 (2021). https://www.ais.gov.au/__data/assets/pdf_file/0008/734363/Considerations-of-training-load-in-relation-to.pdf
11. Humphrey L (Hansons Marathon Method excerpt). Mastering the long run. Outside. https://www.outsideonline.com/health/running/training-advice/running-101/mastering-the-long-run/?scope=anon
12. Strava Support. Changing the units of measurement on your Strava account. https://support.strava.com/en-us/articles/15401745-changing-the-units-of-measurement-on-your-strava-account
13. Athletics Weekly (Hansons Marathon Method excerpt). Marathon training: the long run – how far? https://athleticsweekly.com/?p=45900
14. Ramskov D, et al. Run Clever: no difference in risk of injury when comparing progression in running volume and running intensity in recreational runners: a randomised trial. *BMJ Open Sport Exerc Med* 2018;4:e000333. https://bmjopensem.bmj.com/content/4/1/e000333.abstract
15. Silbernagel KG, et al. Continued sports activity, using a pain-monitoring model, during rehabilitation in patients with Achilles tendinopathy: an RCT. *Am J Sports Med* 2007;35(6):897–906. https://search.pedro.org.au/search-results/record-detail/18389
16. Ardern CL, et al. 2016 consensus statement on return to sport from the First World Congress in Sports Physical Therapy, Bern. *BJSM* 2016. https://nih.brage.unit.no/nih-xmlui/bitstream/handle/11250/2428778/ClarsenBritJSportsMed.pdf?sequence=1
17. Silbernagel KG, Hanlon S, Sprague A. [Current clinical concepts review: conservative management of Achilles tendinopathy.] *J Athl Train* 2020. https://pmc.ncbi.nlm.nih.gov/articles/PMC7249277
18. George, Sheerin, Reid. [Scoping review of return to running after tibial bone stress injury.] *Sports Med* 2024. https://link.springer.com/article/10.1007/s40279-024-02051-y
19. Berkshire Healthcare NHS Foundation Trust. [Return-to-running patient leaflet, Feb 2026.] https://www.berkshirehealthcare.nhs.uk/media/2jmpfnad/return-to-running-bh1165q-feb-2026.pdf
20. BJSM blog (2019). Graded return-to-run program for bone stress injury, adapted from Warden et al. 2016 (Table D). https://blogs.bmj.com/bjsm/files/2019/05/Table-D-Graded-Return-to-Run-Program-for-Bone-Stress-Injury-adapted-from-Warden-et-al-2016.pdf
21. Silbernagel KG. Tendinopathy and Sports, course handout. McKenzie Institute USA. https://www.mckenzieinstituteusa.org/forms/SYLLABUS_Tendinopathy%20and%20Sport%20KGS%20handout.pdf
22. NHS. Knee pain and other running injuries. https://www.nhs.uk/live-well/exercise/running-and-aerobic-exercises/knee-pain-and-other-running-injuries/
23. NHS. Sprains and strains. https://www.nhs.uk/conditions/sprains-and-strains/
24. Ohio State Wexner Medical Center (Miller T, MD; clinical opinion). [Article on runner's knee and other running injuries.] https://wexnermedical.osu.edu/our-stories/runners-knee-injuries
25. Friel J. Aerobic endurance and decoupling. TrainingPeaks. https://www.trainingpeaks.com/learn/articles/aerobic-endurance-and-decoupling/
26. 220 Triathlon. Aerobic decoupling: what it is, how it works and why it's important. https://www.220triathlon.com/training/aerobic-decoupling-what-it-is-how-it-works-and-why-it-s-important
27. Marathon Handbook. [Article on aerobic decoupling.] https://marathonhandbook.com/aerobic-decoupling/
28. Gaudette J. [How to build your long run.] RunnersConnect. https://runnersconnect.net/running-training-articles/build-long-run/
29. Fleet Feet. [Beginner's long-run guide.] https://www.fleetfeet.com/how-to-start-running/beginners-long-run-guide
30. Nike. [How to increase running mileage.] https://www.nike.com/a/how-to-increase-running-mileage
