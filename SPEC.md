# Personal Running Coach: Build Spec

Version 0.9, November 24, 2026. Owner: Nick. Builder: Claude Code.

Changes in 0.9: 3.7, 3.8 and F8 give the weather and treadmill rules in full (#4): a temperature-plus-dew-point slow-down table for pace-targeted segments only (half for repeats, none below a sum of 100°F, never faster in any weather), forecast timing and what a stale or missing forecast does, raw and adjusted targets shown and used by live cues, heat safety levels from a shade WBGT estimate against ACSM's most cautious thresholds, a personal heat model and a learned treadmill offset from pace at heart rate, treadmill sessions planned ahead with 1% incline and HR targets; F8's acceptance criteria are testable; temperature joins the units setting; references 56 to 71. The heat safety plan changes are a safety rule waiting for the owner (section 10).

Changes in 0.7: 3.6 gives the default grade-adjusted pace curve (uphill from Minetti et al.'s energy cost of running shifted as Strava's model describes, downhill from Strava's two published points) [33][34]; F11's lap accuracy criterion is stated over many simulated runs, per run type (#2, #5).

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
- **No weather:** activities usually carry none. The app records its own forecast reading at the start of the runs it starts (3.7) and never looks up past weather, which would send a past run's time and place off the device.

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
   - Paces after a break use the Daniels return factor: no change up to 5 days off, about 97% of pre-break VDOT after 2 weeks off without cross-training (97.3%; 98.6% with cross-training) [8]. Built and adapted plans (F3, F4) apply it to training paces only (#28; notes in `docs/research/break-pace-factor.md`):
     - **Days off and the factor.** A break here is 6 or more consecutive days with no running in the run history, or one or more break weeks (the weekly reading below). Its days off are counted from the day after the last run before it to the day before the first run after it, with every day of a break week counted as a day off even if it holds a short run; so one or two break weeks count as at least 7 or 14 days, plus the days without a run on either side (the longer reading, and so the larger slow-down). The factor is [8]'s table without cross-training: 1.000 up to 5 days, 0.997 at 6, 0.994 at 7, 0.985 at 10, 0.973 at 14, 0.952 at 21, 0.931 at 28, then 0.021 lower for each further week to 0.805 at 70, and 0.800 at 72 days or more. A day count between two rows takes the longer row's value (8 days uses 0.985) rather than interpolating, since [8] gives only the rows and the longer row is the larger slow-down. The app doesn't ask about cross-training (no manual modes) and doesn't read it from the runner's data, so the cross-training column is never used. The factor scales training speeds (a pace in seconds per km is divided by it) for every pace target taken from the fitness anchor or the easy-pace sample; [8] states the factor on VDOT, and the app paces from a race anchor (3.9) rather than VDOT, so applying it to speed is a heuristic. Heart-rate targets, the race goal, the race-time prediction (3.9) and race-day pacing (F12) are unchanged.
     - **When it ends.** After a short break (6 to 14 days off, or one or two break weeks), the factor is lifted back over the three weeks after the break, in step with the return ramp (week 1 is the ramp's week 1, or, after a break with no break week, the week of the first run back): week 1 at the factor, week 2 halfway between it and 100%, and 100% from week 3, the ramp's full-volume week, never earlier. After a longer break (three or more break weeks, or more than 14 days off that is not a short break by weeks), there is no ramp to lift it over, so the factor holds until a new fitness anchor replaces it, as [8] says to update VDOT from race times once racing resumes (the conservative reading). In either case, only a run marked as a race or time trial after the break becomes the fitness anchor and ends the factor; a best effort from training does not. Through the third week after the break, no training pace is faster than its pre-break value. [8]'s table is a coaching table, not a study. Every figure here except that table is a heuristic: the day counting, taking the longer row, applying the factor to speed, and the halfway step. [8]'s weight adjustment is not used, because the spec reads no body weight and the step matters only when weight changed during the break.
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
- Strava's GAP model (2017; we couldn't confirm it is still the one Strava uses) was fitted from heart rate across about 6 million runs [34]: efficiency (HR per unit speed) as a function of gradient. Its downhill benefit bottoms out around -9% (pace factor 0.88) and returns to flat by about -18%.
- **Rule:** use a GAP curve as the default and personalize it from the athlete's own HR-versus-grade data once there are enough steady hilly runs. Targets on hilly routes are set in grade-adjusted pace.
- **Default curve.** On a grade g (rise over run, 0.05 = 5%), the target running pace is the grade-adjusted target pace times a factor f(g); f above 1 is slower, below 1 faster. Grades are clamped to -45% to +45%, the range Minetti et al. measured [33].
  - Uphill (g above 0): f(g) = Cr(g - 0.02) / Cr(0), and never below 1 (the floor is a heuristic: the shifted curve is about 0.90 on the flat and stays under 1 up to +2%), where Cr(i) = 155.4i^5 - 30.4i^4 - 43.3i^3 + 46.3i^2 + 19.5i + 3.6 (J/kg/m) is Minetti et al.'s energy cost of running [33]. Strava reports that for positive gradients its heart-rate model's slope almost matches the Minetti-based model, "shifted to the right by about 2%" [34]; reading that as 2 percentage points of grade is our interpretation. This gives about 1.06 at +3%, 1.17 at +5%, 1.51 at +10% and 2.32 at +20%, and 1.0 up to +2%.
  - Downhill (g below 0): f falls in a straight line from 1.0 at 0% to 0.88 at -9%, rises in a straight line back to 1.0 at -18%, and stays at 1.0 on steeper descents. The two points are Strava's published minimum and its return to flat [34]; the straight lines between them, and holding 1.0 past -18% ([34] gives no values past -18%), are heuristics. Minetti's lab costs keep falling to -20% [33], but Strava's real-world data show a much smaller downhill benefit [34], so Minetti is not used downhill.
  - Evidence: Minetti et al. is a treadmill study of 10 elite mountain runners [33]; Strava's model is fitted from heart rate on about 6 million real runs but is published only as a figure, not a formula [34]. So the curve is a reasonable default, not a validated model, which is why the rule above replaces it with the runner's own curve once their data allow.

### 3.7 Heat and humidity
- Across 1.8 million marathon finishes, performance follows a quadratic curve with temperature; the best temperature is about 3.8 to 9.9°C depending on ability, and pace falls off increasingly as it gets warmer [56]. In seven marathons, top men were 1.7% off the course record at WBGT 5 to 10°C and 4.5% at 20 to 25°C [58]. Studies disagree on who loses more: slower finishers in [58][59], faster runners in a pacing abstract [57] and in one New York study [61]; across 1,258 elite races the loss was about 0.4% per °C of WBGT above the best (0.2% for the marathon) [60]. These are race results for groups. No study gives a pace adjustment for a training session, so the table below is a coaching convention, checked only for size against the race data (`docs/research/weather-treadmill-evidence.md`).
- **Rule:** heart-rate-governed running needs no heat math; HR already rises in heat. Pace-targeted segments are slowed by the temperature-plus-dew-point table below until the runner's own model (below) replaces it. The app shows both the raw and the adjusted target so the athlete can see why. Heat never makes a target faster, and neither does cold or wind.
- **Inputs.** The forecast air temperature T and dew point Td (°C) for the hours the session covers: every forecast hour that overlaps the session's start to its start plus its planned duration. The engine uses the hour with the highest T + Td, and for heat safety the hour with the highest WBGT estimate. When a source gives relative humidity RH (%) and not dew point, Td comes from the Magnus formula with A = 17.625 and B = 243.04°C: γ = ln(RH/100) + A·T/(B + T), Td = B·γ/(A − γ) [65]. WeatherKit's hourly forecast has `temperature` and `dewPoint` (and `humidity` as a fraction, so RH = 100 × humidity) [68]; Open-Meteo has `temperature_2m` and `dew_point_2m`. Weather inputs are kept in SI (°C) inside CoachCore like everything else.
- **The session's start.** F2 asks no run time, and a planned session's date carries a noon placeholder time of day (the plan builder's, chosen to stay clear of daylight-saving changes); that placeholder is never used as a start time. Before the run, the start is inferred: the median start time of day (local time, rounded down to the hour) of the runner's outdoor runs in the last 28 days on the same weekday, if there are at least 3; otherwise the same over all weekdays in the last 28 days, if there are at least 3. With neither, there is no pre-run adjustment and no pre-run heat level, the session says "Adjusted for heat when you start", and only the reading at session start is used. Once the runner starts the session, its actual start replaces the inferred one. Workouts run in the native Workout app (F10) have no start the app can see, so without an inferred start they get no heat adjustment. The 28 days and 3 runs are heuristics.
- **Which segments are adjusted.** Only segments whose target is pace-primary (F3: threshold, VO2max and race-pace work, and the race itself until F12's race-day plan exists). HR-primary segments (easy, recovery, steady, the jog between reps, every warm-up and cool-down, and whole easy and long runs) keep their raw pace range, which is a guide under the heart-rate target. A `work` segment of at most 8 minutes gets half the adjustment; every other pace-primary segment (`main`, `finish`, and `work` reps longer than 8 minutes) gets all of it. Halving for repeats is the table's own convention, given for 400 m to mile repeats, because the body cools in the recoveries [62]; the 8-minute limit, which keeps long threshold intervals at the full adjustment, is our heuristic.
- **The adjustment (heuristic).** S = (T × 1.8 + 32) + (Td × 1.8 + 32), the sum of both in °F, so S = 1.8 × (T + Td) + 64. The slow-down p (% of pace) is piecewise linear through these points, the endpoints of Hadley's bands [62]:

  | S (°F) | 100 or less | 110 | 120 | 130 | 140 | 150 | 160 | 170 | 180 or more |
  |---|---|---|---|---|---|---|---|---|---|
  | T + Td (°C) | 20.0 or less | 25.6 | 31.1 | 36.7 | 42.2 | 47.8 | 53.3 | 58.9 | 64.4 or more |
  | p | 0 | 0.5% | 1.0% | 2.0% | 3.0% | 4.5% | 6.0% | 8.0% | 10.0% |

  Reading each band's range as a straight line between its ends is our choice; the table gives only ranges. p stays at 10% above S = 180, where the table says hard running is not recommended; the heat safety rule below handles those conditions. Adjusted pace = raw pace × (1 + p/100) at both ends of the range (seconds per km). For example, 25°C with a dew point of 18°C gives S = 141.4 and p = 3.2%, so a 240 s/km threshold target becomes 247.7 s/km. Evidence: the table is a coaching convention with no data behind it [62], and other coaching tables disagree [63]; at moderate heat its size matches the elite race data [58][60]. Strength: weak.
- **Cold and wind.** No adjustment in either direction. Cold slows elite racers a little (about 0.1 to 0.3% per °C below the best [60]), but the effect is small next to forecast error, and forecast wind at 10 m is not the wind a runner meets on a route. Conservative default (heuristic).
- **When the forecast is read.** The app reads the hourly forecast for the device's current location, on the morning of the session (with the readiness check, F5), again about 2 hours before the inferred start, and when the runner starts the session. Only the device's current location goes to the weather service, and only at those read times: no health data, no run history, and never a past run's time or place (the app never looks up historical weather). The reading at session start is stored on the device with the run; it is the only weather the personal model (below) and the treadmill offset (3.8) use. The adjustment uses the latest reading. A reading is **stale** when it was fetched more than 6 hours before the session starts or when no forecast hour covers the session (heuristic). With a stale or missing reading, or a missing temperature or dew point, there is no adjustment and no heat safety level, and the session says so ("No current forecast, so targets are not adjusted for heat"). The engine never guesses weather. Workouts synced ahead to the Workout app (F10) carry raw targets; when a reading changes today's session, the app re-syncs it.
- **How it reaches the runner.** Each adjusted segment shows the raw and the adjusted range, the percentage and the conditions it came from, through the units formatter (for example "Threshold 4:00–4:05/km, heat-adjusted 4:08–4:13/km (+3.2%, 25°C, dew point 18°C)"). Live cues (F11) use the adjusted range; on hills the GAP factor (3.6) multiplies the adjusted flat target. A run's comparison with its plan (F4, F6) uses the target that was shown for it, so heat doesn't read as being behind plan.
- **Heat safety (a safety rule; the plan changes wait for the owner).** The app estimates shade WBGT from the forecast: RH from T and Td by the Magnus relation [65], wet-bulb temperature by Stull's formula, Tw = T·atan(0.151977·(RH + 8.313659)^0.5) + atan(T + RH) − atan(RH − 1.676331) + 0.00391838·RH^1.5·atan(0.023101·RH) − 4.686035 (T in °C, RH in %, angles in radians; valid for RH 5 to 99% and T -20 to 50°C at sea-level pressure, mean absolute error 0.28°C; RH is clamped to 5 to 99% for it, a heuristic) [66], then WBGT = 0.7 × Tw + 0.3 × T, the no-sun WBGT with the globe taken as the air temperature [67]. That last step is our simplification and reads low in sun; the app doesn't know whether the runner is acclimatized. So the levels use the most cautious column and region of ACSM's 2023 table (training for nonacclimatized, unfit or high-risk people, region category 1) [64]:

  | Shade WBGT (°C) | Level | Shown | Plan change (waits for the owner, see section 10) |
  |---|---|---|---|
  | below 15.1 | none | adjusted targets only | none |
  | 15.1 or more | fluids | a note to drink and carry water | none |
  | 19.0 or more | caution | a heat warning on every outdoor session | none |
  | 22.4 or more | high | a warning and a suggestion: the coolest forecast hour of the day, or a treadmill if the runner has access (F2) | quality sessions turn HR-primary (pace shown as a guide only), and their work time is cut to 75% |
  | 26.8 or more, up to 29.0 | severe | a strong warning to move indoors or to a cooler hour | any outdoor run becomes an easy run by heart rate of at most 60 minutes |
  | over 29.0 | extreme | "Don't run outside now" | the outdoor session is cancelled and handled as a missed day (F4), or moved to a treadmill session if the runner has access |

  ACSM's actions for those bands are: monitor fluids; shorten total duration; reduce intensity and duration; limit exercise to an hour; cancel [64]. Each level runs from its lower bound up to the next level's, so there are no gaps, and 29.0 sits in severe, where ACSM puts it. "High" merges ACSM's moderate-high and very high rows (22.4 to 24.5 and 24.6 to 26.7). That merge and the mapping to running sessions (HR-primary, 75% of work time, 60 minutes) are our heuristics. ACSM's table is expert consensus for team sports and events, in US regions, and says to adapt thresholds to the local climate [64]; the shade estimate is not a measured WBGT. Strength: the thresholds are the accepted standard; the mapping and the estimate are heuristics.
  - **Until the owner decides,** the app shows the level and the warning and changes nothing else; the "Plan change" column is written but off. Once switched on, every changed session passes the F9 checker, and its note names the level and the conditions. If the owner picks option C of section 10's question 1, the runner can still run the original session with one tap from the warning (heuristic). A changed or cancelled session isn't counted as a missed target (F4), and the time it lost is not added back elsewhere in the week.
  - A sun allowance (raising the estimate in daylight from WeatherKit's `isDaylight`, `uvIndex` and `cloudCover` [68]) is a possible later refinement; it is not part of this rule.
  - The goal race gets the level and the warning only; this rule never changes or cancels it.
  - Sessions on a treadmill (3.8) get no heat adjustment and no heat level: they are indoors.
- **Personal model (replaces the table once fitted).** It fits the runner's own pace at heart rate against conditions.
  - **Qualifying runs:** outdoor runs in the last 365 days with a heart-rate stream and a weather reading the app recorded itself at the run's start (above), stored on the device with the run. Runs without one (imported history, runs started outside the app) never qualify, so the model needs runs started through the app and starts empty for every runner. Qualifying runs are not hilly (under the climb-per-km limit F4 already uses to skip pace comparisons on hilly routes), with a main part (after the warm-up, 3.3) of at least 20 minutes whose average HR is below the top of zone 2 (3.2). Treadmill runs never count.
  - **Measure:** efficiency E = main-part average speed (m/s) / main-part average HR (bpm). A run with S of 120 or more (a table adjustment of at least 1%) is a **warm** run. Its cool reference is the median E of qualifying runs with S of 100 or less within 42 days before or after it, and needs at least 3 of them; a warm run without one doesn't count. Its slow-down y = (E_cool / E − 1) × 100, the % slower pace at the same HR.
  - **Fit:** y = m × p(S), where p is the table above and m is fitted by least squares through the origin over the warm runs (m = Σ y·p / Σ p²), refitted weekly. m is clamped to 0 to 2 (heuristic). A model needs at least 8 warm runs, at least 3 of them with S of 130 or more (heuristic). Below that the table is used.
  - **Use:** the personal slow-down is m × p(S), halved for repeats like the table, applied only up to 10°F of S above the warmest warm run in the fit (the limit); past the limit it is max(m, 1) × p(S), with p capped at 10% as before, so the slow-down never falls as S rises. It can never make a target faster than raw (m ≥ 0). Whether it may come out below the table (m under 1) is an owner question (section 10); until answered, the engine uses the larger of the personal and the table slow-down.
  - Strength: heuristic. Pace at HR on one day carries noise from sleep, hydration and drift; the minimum counts and the clamp keep one odd run from moving a target.

### 3.8 Treadmill
- A 1% treadmill grade best matched the oxygen cost of level road running at 2.92 to 5.0 m/s (about 9:11 to 5:22 per mile) in nine trained men used to treadmills [69]. A 2019 review of 34 crossover studies found no overall difference in submaximal oxygen cost, so the 1% convention was not clearly needed at those speeds; at 1%, submaximal HR was about 3 bpm higher on the treadmill (moderate certainty), and the HR gap changed with speed (higher on the treadmill at faster speeds, lower at slower ones) [70]. Running mechanics are mostly similar (contact time about 5 ms longer on the treadmill; low certainty) [71]. So the average treadmill-outdoor gap is small but differs by runner and speed, which is why the offset is learned. Strength: moderate for "small on average", weak for any one runner.
- **Rule:** treadmill sessions default to 1% incline and use HR as the primary target. Learn the athlete's treadmill offset (pace at the same HR, treadmill versus outdoor) from the runner's treadmill history, and apply it to the pace shown on treadmill sessions.
- **Knowing a run was on a treadmill.** The F1 tagger decides (section 2): the source's own treadmill flag when present, in either direction; otherwise HealthKit's indoor-workout flag with no GPS route and no altitude stream. An indoor run with a route or altitude is left untagged, because the evidence conflicts. A run the app's own watch app records (F11) as an indoor session is a treadmill run.
- **Planning a treadmill session.** The runner can mark any planned session as treadmill ahead of time, and the app offers it on a high, severe or extreme heat level (3.7) when the runner has treadmill access (F2). A treadmill session keeps its segments and durations. Every segment is HR-primary, with the same HR targets as outdoors. It has no heat adjustment and no GAP. It says "Set the incline to 1%". It syncs to the Workout app as an indoor workout (F10). Its pace range is shown as a guide: the outdoor raw range divided by (1 + o), where o is the offset below (o > 0 means the runner goes faster on the treadmill at the same HR). Until o is learned, the guide is the outdoor raw range, labelled "outdoor pace, treadmill not yet calibrated". Live cues (F11) on a treadmill come from heart rate only.
- **The offset (heuristic).** o is fitted from pace at HR, like the heat model:
  - **Qualifying treadmill runs:** treadmill-tagged runs in the last 180 days with a heart-rate stream, a recorded speed or distance, and a main part (after the warm-up, 3.3) of at least 20 minutes whose average HR is below the top of zone 2. Their efficiency E_t = main-part average speed / average HR. The speed is whatever the run recorded (the watch's own estimate indoors, or a treadmill's), so o also absorbs the watch's indoor speed error, which is what the cues read.
  - **Outdoor reference:** the median E of qualifying outdoor runs as in 3.7's personal model (so only runs with a weather reading the app recorded at their start), with S of 100 or less (no heat slow-down), within 28 days before or after the treadmill run, at least 3 of them; a treadmill run without one doesn't count.
  - **Fit:** each qualifying treadmill run gives o_i = E_t / E_outdoor − 1. o is the median of the latest 6 o_i, needs at least 4 of them, and is clamped to -10% to +10%. It is refitted after each treadmill run.
  - **Use:** o comes from easy running and is applied to every treadmill pace guide; the review found the gap changes with speed [70], so quality paces on a treadmill stay guides under HR. A treadmill run's pace is compared with its plan (F4, F6) only once o is learned, against the treadmill guide; before that it is not compared (as the debrief already says).
  - The minimum of 4 runs, the 28-day window, the 180-day history and the ±10% clamp are heuristics.

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
- **Easy runs and the long run.** No easy run is longer than the week's long run, and no training run goes past the long-run time cap that applies to it (3.5 rule 5) or the runner's max session length (F2). In a week with no long run, easy runs stay within those two limits. The race is not a training run: it is exempt from these limits (3.5 rule 3) and doesn't count as the week's long run. When a week's volume doesn't fit within these limits on the runner's days, the easy time held back goes first to other easy runs and free days, then to the week's quality sessions as easy running at the end of the cool-down, so the hard minutes stay as planned. Each quality session may grow up to the week's long run, the long-run cap and the max session length, and the time never goes to the long run itself, which would only raise the limit it was held to. Only what still doesn't fit makes the week smaller, still within 3.1's 75 to 85% easy share (so quality time shrinks with it), and its note says why, instead of piling the extra time onto one easy run (#23). Moving the time to the cool-down keeps 3 and 4 day weeks near their planned volume, at the cost of a long workout day (for example, 103 minutes on a 10K plan at 330 minutes on 3 days: 15 warm-up, 42 of reps and recovery jogs, and 46 easy). Planning those weeks smaller instead, as the first version of PR #53 did, cut them to about 165 to 209 minutes (heuristic; owner's decision, "Keep long workout days", #70). Coaches define the long run as the week's longest run [31] and treat it as the longest training day [11]. Only the long run has F3's 10-minute weekly growth limit, so an easy run longer than it would set the 30-day spike baseline (3.5 rule 1) without that limit [1]. No study tests a limit on easy-run length, so this is coaching convention (heuristic; owner's decision, #23).
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
- Pulls a forecast for the session's start (inferred from the runner's own start times, 3.7) and adjusts pace targets per 3.7; shows raw and adjusted. Gives each outdoor session its heat safety level and warning (3.7); the level's plan changes stay off until the owner approves them (section 10).
- Fits the runner's personal heat model (3.7) and treadmill offset (3.8) from their own runs, and uses the table and an uncalibrated treadmill guide until there are enough.
- Treadmill mode per 3.8: tagged runs, sessions planned as treadmill ahead of time, 1% incline, HR-primary targets and an offset pace guide.
- **Accept when:**
  - The slow-down matches the 3.7 table at its points and is linear between them: for example T + Td = 20.0°C (S = 100) gives 0, S = 125 gives 1.5%, S = 145 gives 3.75% and S = 200 gives 10%. Below S = 100, in cold or in wind, every target equals its raw value exactly, and no adjusted target is ever faster than raw.
  - The session's start: with 3 or more outdoor runs on that weekday in the last 28 days, their median start hour is used; with fewer, the median over all weekdays; with fewer than 3 runs in all, no pre-run adjustment or heat level and the "adjusted when you start" note, and the reading at start is used once the session starts. The noon placeholder is never used as a start time.
  - Only pace-primary segments change; a `work` segment of 8 minutes or less gets half the slow-down and a longer one all of it; HR targets, warm-ups, cool-downs and easy and long runs are unchanged.
  - Dew point from relative humidity, Stull's wet-bulb temperature and the shade WBGT match the 3.7 formulas on a table of synthetic inputs, and each WBGT band gives its 3.7 level.
  - The session's hours: with two forecast hours under a session, the warmer one's S and WBGT are used.
  - A reading more than 6 hours old, a forecast with no hour over the session, or a missing temperature or dew point gives raw targets, no heat level and the "no current forecast" note.
  - With the owner's switch off, no heat level changes a session; with it on, each level makes exactly the 3.7 change, and every changed plan passes the F9 checker.
  - The plan, the debrief and the watch show raw and adjusted ranges in the runner's units; a simulated hilly run held at the adjusted target triggers no "speed up" cue, and the cue engine's target equals the adjusted flat target times the GAP factor.
  - Personal model: on synthetic histories with a planted heat effect of m = 1.5, the fit is within 0.1 of it once the minimum data exist, and the table is used before that; under question 3's option A, a planted m of 0 gives raw targets, never faster ones; under the default (option B, until the owner answers) a planted m of 0 gives the table's slow-down, and no target is less slowed than the table. For any fitted m from 0 to 2, the adjusted slow-down is non-decreasing in S, including across the model's limit. Only runs with a weather reading recorded at their start count; imported runs without one leave the model empty.
  - Treadmill: on synthetic histories with a planted offset of +4%, the learned offset is within 1 percentage point after 4 qualifying runs; with 3 runs the guide is the outdoor raw range, labelled uncalibrated; a planted +15% is clamped to +10%. A session marked as treadmill is HR-primary in every segment, says 1% incline, has no heat or GAP adjustment and syncs as indoor.

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
- **Accept when:** replaying simulated recordings (synthetic streams with GPS noise, hills and pace changes) through the cue engine gives no more than one false "speed up" per hilly mile, and the cue engine's pace estimate tracks lap-average pace within 5 sec/mile. Read over many simulated runs: for each run type on its own (steady, progression, repeats, and hilly with GPS dropouts), over at least 200 seeded runs of that type, at least 95% of full-mile laps are within 5 sec/mile and none is off by more than 10 sec/mile. Some steady-run laps can't meet 5 sec/mile even from the plain mean of their GPS readings (PR #81's review), so "every lap" would test the simulated noise rather than the engine. The share and the cap are heuristics.

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
- The runner chooses metric (km, min/km, metres of climb) or imperial (miles, min/mi, feet of climb) in Settings. The default comes from the device's measurement system: US locales get imperial, everyone else metric. Temperatures follow the same choice (°C for metric, °F for imperial). Changing it re-words text only; it never changes a target, a limit or a plan decision.
- CoachCore computes in SI units (seconds, metres, seconds per km). Every user-facing distance, pace, climb and temperature (debrief, weather notes, progress summary, plan and goal text, adaptation details) goes through one formatter, which converts before rounding (1 mi = 1609.344 m, 1 ft = 0.3048 m exactly, °F = °C × 1.8 + 32). The F6 contract holds in both units: shown numbers are the formatter applied to the facts, and every stated comparison holds on the numbers shown in the runner's unit.

## 5. Data sources

| Source | What it gives | How | Notes |
|---|---|---|---|
| Apple HealthKit (primary) | Workouts with routes; HR; running power, speed, stride length, ground contact, vertical oscillation; steps (cadence); HRV (SDNN), resting HR, HR recovery, VO2max estimate, sleep, respiratory rate | Native iOS app | Needs an iPhone app with HealthKit permission; no web access to HealthKit. |
| Strava API (optional) | Activities and streams (HR, cadence, altitude, velocity, grade, power), best efforts | OAuth, webhooks | See 5.1 on terms. Useful only for runs not in Apple Health. |
| Weather | Hourly forecast for the device's current location | WeatherKit or Open-Meteo | Activities usually carry no weather; no historical lookups (3.7). |
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
  6 to 14 days (or 1 to 2 break weeks): week 1 ~60-70% of pre-break volume, no hard sessions;
                week 2 ~80-90%, one quality session; week 3 full
                paces x Daniels return factor [8] (no cross-training; 0.973 at 14 days, longer row between rows):
                  week 1 x factor, week 2 halfway, 100% from week 3; only a race or time trial marked as one after the break ends it
                during the ramp, 10% weekly and rolling 4-week checks measure against pre-break volume
                first long run back must pass the 30-day spike rule
  > 14 days: normal progression; paces x Daniels return factor until a new race or time trial
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

The goal race, date, distance and time goal are set and edited in the app (F2).

Weather and treadmill questions for the owner (#4; the evidence check is in `docs/research/weather-treadmill-evidence.md`). Until they are answered, the app keeps the safe default named in each:
1. **Do hot conditions only warn, or also change the session?** (A) Warn only. (B) Warn, and make 3.7's plan changes at the high, severe and extreme levels. (C) As B, but the runner can keep the original session with one tap from the warning. Pick: C. Deciding fact: ACSM's guidance is to reduce, shorten or cancel at these levels [64], and the app can't see acclimatization, so a warning alone leaves the hardest call to the runner in the worst conditions. Default until answered: A.
2. **Which ACSM thresholds?** (A) Region category 1, the most cautious (caution from a shade WBGT of 19.0°C). (B) Category 2 (caution from 21.0°C). (C) A category from the runner's local climate, which needs climate data the app doesn't have. Pick: A. Deciding fact: the shade estimate reads low in sun and the app doesn't know whether the runner is acclimatized [64][67]. Default until answered: A.
3. **May the personal heat model slow targets less than the table?** (A) Yes, from 0 to 2 times the table. (B) No, never less than the table. Pick: A. Deciding fact: the table is one coach's convention with no data behind it [62], while the model is the runner's own pace at heart rate, and the heat safety levels apply either way. Default until answered: B.

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

Numbered citations in sections 3.3, 3.5, 3.6, 3.7, 3.8, 10 and F3. References 1 to 15 match `docs/research/spec-evidence.md` (which also lists 20), 15 to 24 match `docs/research/pain-return-evidence.md`, 25 to 30 match `docs/research/short-long-run-progression.md`, 31 to 32 match `docs/research/easy-run-length.md`, 33 to 34 match `docs/research/grade-adjusted-pace.md` and 56 to 71 match `docs/research/weather-treadmill-evidence.md`; those files record what each source was read for. Reference 12 (units) is listed there and not yet cited here, and references 26, 27, 30 and 32 are listed as background and not cited here. References 35 to 55 are reserved for the readiness rule (PR #86). A description in square brackets stands in for a title that was not recorded when the source was read.

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
31. Fitzgerald J. The Almighty Long Run: The Case for Running Long. Strength Running, 2016. https://strengthrunning.com/2016/08/long-run-case-for-running-long/
32. Beck K. The Medium-Long Run: A Triathlete's Secret Weapon (on Pfitzinger's medium-long run). Active.com. https://www.active.com/running/articles/the-medium-long-run-a-triathlete-s-secret-weapon
33. Minetti AE, Moia C, Roi GS, Susta D, Ferretti G. Energy cost of walking and running at extreme uphill and downhill slopes. *J Appl Physiol* 2002;93(3):1039–1046. https://iris.unibs.it/retrieve/ddc633e4-3c03-4e2e-e053-3705fe0a4c80/Minetti%20JAP%202002.pdf
34. Robb D. An improved GAP model. Strava Engineering, 2017. https://medium.com/strava-engineering/an-improved-gap-model-8b07ae8886c3

56. El Helou N, Tafflet M, Berthelot G, et al. Impact of environmental parameters on marathon running performance. *PLoS ONE* 2012;7(5):e37407. https://pmc.ncbi.nlm.nih.gov/articles/PMC3359364/
57. Ely MR, Martin DE, Cheuvront SN, Montain SJ. Effect of heat stress on marathon pacing is dependent on runner ability. ACSM 55th Annual Meeting, 2008, abstract 1932. Summary: https://coachsci.sdsu.edu/csa/vol145/ely.htm
58. Ely MR, Cheuvront SN, Roberts WO, Montain SJ. Impact of weather on marathon-running performance. *Med Sci Sports Exerc* 2007;39(3):487–493. doi:10.1249/mss.0b013e31802d3aba. https://experts.umn.edu/en/publications/impact-of-weather-on-marathon-running-performance/
59. Montain SJ, Ely MR, Cheuvront SN. Marathon performance in thermally stressing conditions. *Sports Med* 2007;37(4–5). https://www.springermedizin.de/marathon-performance-in-thermally-stressing-conditions/12122196
60. Mantzios K, Ioannou LG, Panagiotaki Z, et al. Effects of weather parameters on endurance running performance: discipline-specific analysis of 1258 races. *Med Sci Sports Exerc* 2022;54(1):153–161. doi:10.1249/MSS.0000000000002769. https://pmc.ncbi.nlm.nih.gov/articles/PMC8677617/
61. Gasparetto T, Nesseler C. Diverse effects of thermal conditions on performance of marathon runners. *Front Psychol* 2020;11:1438. doi:10.3389/fpsyg.2020.01438. https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2020.01438/pdf
62. Hadley M. Temperature + dew point. Maximum Performance Running (blog), 24 July 2013. https://maximumperformancerunning.blogspot.com/2013/07/temperature-dew-point.html
63. Gaudette J. How to adjust your pace in hot and humid weather. RunnersConnect, updated 2026. https://runnersconnect.net/running-training-articles/dew-point-effect-running/
64. Roberts WO, Armstrong LE, Sawka MN, Yeargin SW, Heled Y, O'Connor FG. ACSM expert consensus statement on exertional heat illness: recognition, management, and return to activity. *Curr Sports Med Rep* 2023;22(4):134–149. https://pmc.ncbi.nlm.nih.gov/articles/PMC10041407/ (read from a copy hosted by KHSAA: https://khsaa.org/common_documents/Sports%20Medicine/EHIPositionStatement//B-ACSM%20EHI%20Consensus%20Statement%202023.pdf)
65. Lawrence MG. The relationship between relative humidity and the dewpoint temperature in moist air. *Bull Am Meteorol Soc* 2005;86(2):225. https://inspectapedia.com/Environment/Dew-Point-Calculation-Lawrence.pdf
66. Stull R. Wet-bulb temperature from relative humidity and air temperature. *J Appl Meteorol Climatol* 2011;50(11). doi:10.1175/JAMC-D-11-0143.1. https://scispace.com/pdf/wet-bulb-temperature-from-relative-humidity-and-air-3ltrqtnqa1.pdf
67. Dimiceli VE, Piltz SF. Estimation of black globe temperature for calculation of the WBGT index. US National Weather Service. https://www.weather.gov/media/tsa/pdf/WBGTpaper2.pdf
68. Apple. WeatherKit: HourWeather. https://developer.apple.com/documentation/weatherkit/hourweather
69. Jones AM, Doust JH. A 1% treadmill grade most accurately reflects the energetic cost of outdoor running. *J Sports Sci* 1996. https://read.qxmd.com/read/8887211/a-1-treadmill-grade-most-accurately-reflects-the-energetic-cost-of-outdoor-running
70. Miller JR, Van Hooren B, Bishop C, Buckley JD, Willy RW, Fuller JT. A systematic review and meta-analysis of crossover studies comparing physiological, perceptual and performance measures between treadmill and overground running. *Sports Med* 2019;49(5):763–782. https://cris.maastrichtuniversity.nl/ws/portalfiles/portal/53120529/Hooren_2019_A_Systematic_Review_and_Meta_Analysis_of_Crossover_Studies.pdf
71. Van Hooren B, Fuller JT, Buckley JD, et al. Is motorized treadmill running biomechanically comparable to overground running? A systematic review and meta-analysis of cross-over studies. *Sports Med* 2020;50(4):785–813. https://pmc.ncbi.nlm.nih.gov/articles/PMC7069922/
