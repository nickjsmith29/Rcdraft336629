# Grade-adjusted pace: the default curve (SPEC 3.6)

Read on 23 Nov 2026 for the CueEngine's hill targets (#2) and hill-adjusted targets (F7 part 1, #5). Not a training-load, recovery or safety rule: it sets how a pace target is translated onto a slope. Whether a descent should ever cue "speed up" is a separate question for the owner.

## Sources read

**[33] Minetti AE, Moia C, Roi GS, Susta D, Ferretti G. Energy cost of walking and running at extreme uphill and downhill slopes. J Appl Physiol 2002;93:1039–1046.** Peer-reviewed. 10 male elite mountain runners (VO2max about 69 ml/kg/min) on a treadmill at slopes from -45% to +45%. The energy cost of running on the level was 3.40 J/kg/m, independent of speed, and lowest at about -20% (1.73 J/kg/m). The paper fits Cr(i) = 155.4i^5 - 30.4i^4 - 43.3i^3 + 46.3i^2 + 19.5i + 3.6 (J/kg/m, i as a fraction, R^2 = 0.999). The minus signs were lost in the PDF's text extraction; the signs here are the ones that reproduce the paper's reported values (Cr(-0.20) = 1.80, near the measured 1.73; Cr(+0.45) = 19.4). The polynomial's value on the level is 3.6, not the measured 3.40; the spec divides by Cr(0) = 3.6 so the factor is exactly 1 on the flat.

**[34] Robb D. An improved GAP model. Strava Engineering, 2017.** Not peer-reviewed. About 6 million runs from 240,000 athletes with elevation change and heart rate; steady 60-second windows; efficiency (heart rate over speed) by gradient, normalized to the runner's own near-flat efficiency. Findings used here: downhill benefit bottoms out at a pace factor of 0.88 at -9% and is back to 1.0 by -18% (the older Minetti-based model gave about 0.5 at -18%); for positive gradients the slope is almost equal to the Minetti-based model, shifted right by about 2 percentage points. The curve is published only as a figure, with no formula or table. The post names its own caveats: selection bias at steep grades, filtering bias, and an assumed linear heart-rate-to-pace link. It is from 2017; I could not confirm it is still Strava's current model.

Also read, not cited: Schroeder A, "Reverse-engineering Strava's Grade Adjusted Pace" (2023), which fits a degree-5 polynomial to the author's own Strava data; the coefficients are only in a notebook and the fit is checked only on one runner, so it isn't used.

## The default curve (factor f on target pace)

| Grade | -18% and steeper | -9% | 0 to +2% | +3% | +5% | +10% | +20% |
|---|---|---|---|---|---|---|---|
| f | 1.00 | 0.88 | 1.00 | 1.06 | 1.17 | 1.51 | 2.32 |

Uphill f(g) = max(1, Cr(g - 0.02) / Cr(0)). Downhill: straight lines between Strava's points (0%, 1.0), (-9%, 0.88), (-18%, 1.0), then 1.0. Straight lines and the 1.0 hold past -18% are heuristics: Strava's figure is curved and slower than flat past -18%, but publishes no numbers.

## Weak points

- Minetti is lab energy cost in elite mountain runners; Strava is real-world heart rate in a self-selected population; neither is a validated pace model for an individual. SPEC 3.6 already says to personalize from the runner's own HR-versus-grade data once enough steady hilly runs exist.
- The 2-point shift and the downhill points come from a blog post's description of a figure.
- Grade from the watch's altitude is noisy; the code must smooth it over distance (its own named heuristic).
