# Pain stop: end, return, next-morning trigger, clinician flag (issue #73)

Evidence check for SPEC 3.5 rules 1, 4, 6 and 7, Nov 21, 2026. Every number is a heuristic. No study tests return rules for runners whose injury is unknown.

Source numbers in brackets match SPEC.md section 12 and the list at the end of this file; [15] is the same reference as in `spec-evidence.md`. The owner approved all four rules below on Nov 21, 2026, and they are written into SPEC 3.5 (v0.5). The spec also settles details these notes leave open (how usual is computed, seeded from the goal interview and frozen, which rule judges a run, red flags and about 7 days of pain above usual on most days starting a stop, which is a new product decision, the usual +1 allowance on week-1 return runs, rounding a half-point median of usual down, which 2 mornings count before the test run, when a runner counts as staying stopped, and what one step back means; a way out after a clinician has seen a new pain is open in #85); those are product heuristics, see SPEC 3.5 rule 7.

## Summary

| # | Question | Recommended rule (heuristic) | Verdict on spec |
|---|---|---|---|
| 1 | Stop ends | 2 mornings in a row at or below usual pain, pain on daily walking at 2/10 or less, then 1 passed test run | Gap: there is no end today. Add a criteria-based end |
| 2 | Return | Easy runs on alternate days in week 1; long run capped at the ramp fraction; then rule 6 or rule 4, whichever is lower; no quality until 1 symptom-free week; step back on recurrence | Keep rules 4 and 6, and add four guards |
| 3 | Next-morning trigger | Stop at 2+ above usual, 4/10 or more, or above usual at 48 h. A 1-point rise freezes growth | Change: "any pain" is too strict |
| 4 | Clinician flag off | Off only after 3 reports in a row at or below usual; silence never clears it; ask at 7 days, close as unresolved at 14, reopen on a new stop trigger in the same spot within 6 weeks; red flags fire at once | Change: there is no off rule and no red-flag path today |

"Usual" means the runner's own level for that spot: their last stable check-ins, or 0 if they have no pain history.

## 1. When a stop ends

**Rule.** The plan stays at rest or easy-only until all of these hold:
- 2 mornings in a row at or below usual pain.
- Pain on daily walking at 2/10 or less.
- One passed **test run**: easy and flat, 20 to 30 min or half a usual easy run. Pain during it is no more than usual +1 and no more than 3/10. Movement doesn't change. The next morning is at or below usual.

If the stop came from a movement change, the test run must stay at or below usual pain the whole time. If the test fails, the 2-morning count restarts. A stop therefore lasts at least about 3 days.

**Verdict.** The spec has a gap: every stop is permanent. The 2-morning count, the test length and the +1 margin are conventions.

**Sources**
- [16] Ardern et al. 2016, BJSM return-to-sport consensus. Calls for "a graded, criterion-based progression" and notes that most RTS criteria lack solid evidence. https://nih.brage.unit.no/nih-xmlui/bitstream/handle/11250/2428778/ClarsenBritJSportsMed.pdf?sequence=1
- [17] Silbernagel, Hanlon, Sprague 2020, J Athl Train. Start running once pain on daily walking is "minimal (1–2 of 10)." https://pmc.ncbi.nlm.nih.gov/articles/PMC7249277
- [18] George, Sheerin, Reid 2024, Sports Med (tibial bone stress scoping review). Studies require 2 to 28 days of pain-free walking before running. Pain is "the only practical metric." https://link.springer.com/article/10.1007/s40279-024-02051-y
- [19] Berkshire Healthcare NHS FT, return-to-running leaflet (Feb 2026). Run only once you can walk 30 min with no or low symptoms. https://www.berkshirehealthcare.nhs.uk/media/2jmpfnad/return-to-running-bh1165q-feb-2026.pdf

## 2. How the return works

**Rule.**
- **Week 1:** easy runs on alternate days. The long run is capped at the week's ramp fraction of the pre-stop long run (65% under rule 4). After a short stop (5 days off or fewer), where rule 4 has no ramp, the 65% cap applies anyway: a conservative heuristic, approved by the owner on Nov 21, 2026 with the spec (v0.5).
- **Then:** rule 6, back to plan over 1 to 2 weeks and never above it. If the runner took 6 to 14 days off, use rule 4's 65/85/100 ramp, taking whichever of the two gives the lower volume. After more than 14 days off, rebuild under rules 1 and 2.
- **No quality sessions** until 1 full week at plan volume with no symptoms. Distance comes back before speed.
- **Recurrence:** end the run, take a rest day, then go back one step. A second failure at the same step reopens the stop and turns the clinician flag on.

**Verdict.** The spec's shape is right but leaves out four guards: alternate days, distance before speed, the step-back, and the long-run cap. On its own the spike rule doesn't bind here. Its 30-day window still holds the pre-stop runs, so a full-length long run would pass in week 1. No trial compares return ramps.

**Sources**
- [20] Graded return-to-run programme for bone stress injury, adapted from Warden et al. 2016 (BJSM blog, 2019). Progress only when the runner is "symptom free during run", after it and the next day. If symptoms return, stop and drop back a stage after a rest day. https://blogs.bmj.com/bjsm/files/2019/05/Table-D-Graded-Return-to-Run-Program-for-Bone-Stress-Injury-adapted-from-Warden-et-al-2016.pdf
- [18] George et al. 2024. 42% of studies start on alternate days for 2 to 4 weeks, and distance comes before speed. The 10% rule has no validation. https://link.springer.com/article/10.1007/s40279-024-02051-y

## 3. What "still there the next morning" means

**Rule.** Stop if next-morning pain in that spot is any of:
- 2 or more above usual
- 4/10 or more
- still above usual 48 h after the run

A 1-point rise, or a rise over successive weeks, freezes growth for a week, as the check-in rule does. The question asks about one spot, not general muscle soreness.

**Verdict.** The spec should change. "Any next-morning pain, even 1/10" is stricter than every source read. It also stops for good a runner with a stable 1 or 2.

Adopting Silbernagel's limits in full would be too loose. Silbernagel allows up to 5/10 during activity, after it and the next morning, provided pain and stiffness don't rise week to week. But that model was tested in diagnosed Achilles tendinopathy under supervision. Bone stress needs pain-free running, and the app can't tell which tissue is hurting. Reusing the spec's own 4/10 and +2 figures, plus a 48 h limit, is the middle ground.

One wording point: I found no opened source that says "no worse than before the run". That phrasing is a paraphrase, so SPEC shouldn't attribute it to [15].

**Sources**
- [21] Silbernagel KG, "Tendinopathy and Sports" course handout (McKenzie Institute USA). Pain "allowed to reach 5" during and after activity. The morning after "should not exceed a 5". Pain and stiffness may not rise week to week. https://www.mckenzieinstituteusa.org/forms/SYLLABUS_Tendinopathy%20and%20Sport%20KGS%20handout.pdf
- [15] Silbernagel et al. 2007, AJSM. In an RCT of 38 patients, continued running with pain monitoring had no negative effects compared with active rest. https://search.pedro.org.au/search-results/record-detail/18389
- [16] Ardern et al. 2016. Pain no more than 5/10 during activity that "should subside by the next morning", with no week-to-week rise. https://nih.brage.unit.no/nih-xmlui/bitstream/handle/11250/2428778/ClarsenBritJSportsMed.pdf?sequence=1
- [19] Berkshire NHS leaflet. Discomfort that clears within 24 h is fine. Pain lasting more than 48 h, or pain that worsens as you run, is not. https://www.berkshirehealthcare.nhs.uk/media/2jmpfnad/return-to-running-bh1165q-feb-2026.pdf

## 4. When the clinician flag switches off

**Rule.**
- **Fires:** after about 7 days of pain above usual on most days.
- **Fires at once:** on swelling, inability to bear weight, numbness or tingling, sharp pain, or a lasting change in how the runner moves.
- **Switches off:** only after 3 reports in a row at or below usual, at least 1 of them a passed test run.
- **Silence never clears it.** After 7 days with no report, ask once. At 14 days, close the stretch as "unresolved, advice given", and keep the return rules in force.
- **Reopens:** a new stop trigger in the same spot within 6 weeks of the flag turning off or closing reopens the stretch with the flag on.

**Verdict.** The spec should change. 7 days to fire is cautious but within NHS ranges (1 week for knee pain, 2 to 3 weeks for Achilles pain). It has no off rule and no red-flag path. No source sets an off rule, so 3 reports, 14 days and 6 weeks are product heuristics.

**Sources**
- [22] NHS, Knee pain and other running injuries. See a GP or physio for knee pain "if the pain does not go away after a week", and for Achilles pain after "2 to 3 weeks". https://www.nhs.uk/live-well/exercise/running-and-aerobic-exercises/knee-pain-and-other-running-injuries/
- [23] NHS, Sprains and strains. Get urgent help if you can't bear weight, swelling is growing, or there is numbness or tingling. https://www.nhs.uk/conditions/sprains-and-strains/
- [24] Ohio State Wexner Medical Center (Tim Miller, MD; clinical opinion). Stop and seek help if pain "persists after two weeks." https://wexnermedical.osu.edu/our-stories/runners-knee-injuries

## References

Numbering continues from `spec-evidence.md` (1 to 15) and matches SPEC.md section 12. A description in square brackets stands in for a title that was not recorded when the source was read.

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
