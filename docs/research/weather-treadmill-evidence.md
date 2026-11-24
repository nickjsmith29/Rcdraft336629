# Weather and treadmill adaptation (SPEC 3.7, 3.8, F8)

Read on 24 Nov 2026 for #4 (F8). Two parts are safety rules under CLAUDE.md's research rule: when hot conditions shorten, move or switch a session (3.7 "Heat safety"), and the limits on how far a personal model may move a target. The pace slow-down table and the treadmill offset change pace targets only, not training load.

Reference numbers are SPEC.md section 12's. They start at 56 because PR #86 (readiness, still open) uses 35 to 55.

## Heat: performance

**[56] El Helou N, Tafflet M, Berthelot G, et al. Impact of environmental parameters on marathon running performance. PLoS ONE 2012;7(5):e37407.** Peer-reviewed, observational. 1,791,972 finishes, six big-city marathons, 2001 to 2010; weather averaged over each race's first 4 hours. The best air temperature ran from 3.8 to 9.9 °C depending on level; the quadratic fits are modest (r² about 0.24 to 0.27). For elite women, 1 °C above the best temperature cost about 0.03% of speed; the other levels' losses are in a supplementary table I did not read. Humidity correlated weakly with performance at some levels; dew point was mostly not significant. Uses air temperature, not WBGT. Evidence: strong for "warmer is slower" at population level, weak for any per-runner number.

**[57] Ely MR, Martin DE, Cheuvront SN, Montain SJ. Effect of heat stress on marathon pacing is dependent on runner ability. ACSM 55th Annual Meeting, 2008, abstract 1932.** Conference abstract (read on the SDSU coaching-science summary page). 62 race-years of three Japanese women's championship marathons, 5-km splits. Heat slowed the pace of the winner and 25th place most; the 100th place's pace change was the same in cool and temperate races. No pace numbers given. Evidence: weak (abstract only).

**[58] Ely MR, Cheuvront SN, Roberts WO, Montain SJ. Impact of weather on marathon-running performance. Med Sci Sports Exerc 2007;39(3):487–493.** Peer-reviewed, observational (read the abstract on the University of Minnesota research page). Seven marathons over 6 to 36 years, grouped by WBGT quartile. Top men were 1.7% off the course record at WBGT 5 to 10 °C, 2.5% at 10 to 15, 3.3% at 15 to 20 and 4.5% at 20 to 25; top women 3.2, 3.2, 3.8 and 5.4% (not significant between quartiles). The 25th to 300th place finishers slowed more than the winners as WBGT rose (numbers not in the abstract). Evidence: moderate, population level.

**[59] Montain SJ, Ely MR, Cheuvront SN. Marathon performance in thermally stressing conditions. Sports Med 2007;37(4–5).** Peer-reviewed review; abstract only (the full text is behind a login). 140 race-years; times slow progressively once WBGT is above 5 to 10 °C; slower runners lose more; the authors built a nomogram I could not read.

**[60] Mantzios K, Ioannou LG, Panagiotaki Z, et al. Effects of weather parameters on endurance running performance: discipline-specific analysis of 1258 races. Med Sci Sports Exerc 2022;54(1):153–161.** Peer-reviewed, observational, read in full on PMC. 1,258 races (1936 to 2019), 7,867 elite or well-trained athletes. Best performance at WBGT 7.5 to 15 °C (marathon 7.5 °C). Beyond the best, about 0.4 ± 0.4% per °C WBGT in heat and 0.3 ± 0.2% per °C in cold, all events; marathon 0.2% per °C heat and 0.1% per °C cold. Weather from stations about 9 km away; mostly elite fields; decision-tree R² 0.21 to 0.58. Evidence: moderate, population level; underestimates sub-elite losses by the authors' own account.

**[61] Gasparetto T, Nesseler C. Diverse effects of thermal conditions on performance of marathon runners. Front Psychol 2020;11:1438.** Peer-reviewed, observational. Top 1,000 New York City Marathon finishers a year, 2006 to 2018 (11,999 results), WBGT at the start. Slowing began at about WBGT 8 °C; between WBGT 8 and 20 °C the modelled slowdown was 5.4% for the largest (slowest) cluster and 15 to 22% for the faster clusters. One course, start-line weather only, and the sample's slowest runner finished in 3:04. The large effects in the fast clusters contradict [58][59]; I treat them as one course's result, not a general rule.

No study I found gives a pace adjustment for **training** sessions in heat. The race studies measure finishing time against a record, for groups, and mix heat with pacing choices.

## Heat: the temperature-plus-dew-point coaching table

**[62] Hadley M. Temperature + dew point. Maximum Performance Running (blog), 24 July 2013.** This is the table widely shared as the "temp + dew point" rule (read on the author's own blog post). Sum of air temperature and dew point, both in °F, and the pace slow-down for continuous runs:

| Sum (°F) | ≤100 | 101–110 | 111–120 | 121–130 | 131–140 | 141–150 | 151–160 | 161–170 | 171–180 | >180 |
|---|---|---|---|---|---|---|---|---|---|---|
| Slow-down | 0 | 0–0.5% | 0.5–1.0% | 1.0–2.0% | 2.0–3.0% | 3.0–4.5% | 4.5–6.0% | 6.0–8.0% | 8.0–10.0% | hard running not recommended |

For repeats (400s, 800s, mile repeats) the post halves the adjustment, because the body cools in the recoveries. The post cites no study or data; it is one coach's convention, and the author says size, fitness and acclimatization change it. **It is a coaching convention, not research.**

**[63] Gaudette J. How to adjust your pace in hot and humid weather. RunnersConnect (updated 10 Apr 2026).** Cited only to show the tables disagree. A different, dew-point-only table (0% below 55 °F, 1% at 55 to 60, 2 to 3% at 60 to 65, 3 to 5% at 65 to 70, 5 to 8% at 70 to 75, 12 to 15% at 75 to 80, run by effort above 80). It credits no source for the table. Shows that the coaching tables disagree with each other.

**Origin.** I could not trace the temp-plus-dew-point sum to anything older than Hadley's 2013 post; I did not find the Runner's World article the brief mentions. Calling it "Hadley's table" is accurate to what I read.

**Sanity check against the race data.** At 25 °C air and an 18 °C dew point the sum is 141 °F, about 3.2% on the table. The same air has a shade WBGT of about 22 °C (formula below). Ely et al. put top men 2.8 points slower at WBGT 20 to 25 than at 5 to 10 [58]; Mantzios gives about 0.2% per °C above 7.5 °C for marathoners [60], about 2.9%. So the table's mid-range values sit inside the race data for good runners, and slower runners lose more [58][59]. That is agreement in size, not validation.

## Heat: safety thresholds

**[64] Roberts WO, Armstrong LE, Sawka MN, Yeargin SW, Heled Y, O'Connor FG. ACSM expert consensus statement on exertional heat illness: recognition, management, and return to activity. Curr Sports Med Rep 2023;22(4):134–149.** Expert consensus, the latest ACSM statement. The PMC copy (PMC10041407) was behind a browser check, so I read the full statement from a copy hosted by the Kentucky High School Athletic Association. Table 7, "WBGT levels for modification or cancellation of workouts or sports competition for healthy adult athletes", gives WBGT bands (°C) by US region category (1 is the northernmost and coolest, 3 the south). The table's text was partly garbled in that copy; the bands below are the ones that read cleanly. For training of **nonacclimatized, unfit or high-risk** people:

| Action | Category 1 | Category 2 | Category 3 |
|---|---|---|---|
| Increased risk: more rest, monitor fluids | 15.1–18.9 | 17.1–20.9 | 18.4–22.2 |
| Moderate risk: more rest, shorten total duration | 19.0–22.3 | 21.0–24.3 | 22.3–25.6 |
| Moderate-high: reduce intensity and duration | 22.4–24.5 | 24.4–26.5 | 25.7–27.8 |
| Very high: rest:work 1:1, reduce intensity and duration, limit intense exercise | 24.6–26.7 | 26.6–28.7 | 27.9–30.0 |
| Limit exercise to 1 hour or less, no conditioning | 26.8–28.9 | 28.8–30.9 | 30.1–32.2 |
| Extremely high: cancel | >29.0 | >31.0 | >32.3 |

Acclimatized, fit, low-risk people carry on normally to higher bands. Footnotes: the continuous-activity column is for athletes acclimatized for at least 12 weeks; "acclimatized" in the training columns means at least 3 weeks in the heat; adapt thresholds to the local climate. 1 to 2 weeks of heat exposure gives most of the adaptation. Evidence: expert consensus built for team sports and organised events, not a trial; strong as the accepted safety standard. It needs WBGT, which a forecast doesn't give.

Not read: the older ACSM position stand (Armstrong et al. 2007), which the 2023 statement updates.

## Heat: converting a forecast into the inputs

**[65] Lawrence MG. The relationship between relative humidity and the dewpoint temperature in moist air. Bull Am Meteorol Soc 2005;86(2):225.** Peer-reviewed (read on a hosted PDF copy). The Magnus formula with Alduchov and Eskridge's coefficients A = 17.625, B = 243.04 °C gives saturation vapour pressure within 0.4% from -40 to 50 °C. Dew point from temperature t and relative humidity RH: γ = ln(RH/100) + A·t/(B + t), t_d = B·γ/(A − γ). The same relation run the other way gives RH from t and t_d.

**[66] Stull R. Wet-bulb temperature from relative humidity and air temperature. J Appl Meteorol Climatol 2011;50(11).** Peer-reviewed (read on a hosted PDF copy, whose extracted text had some spacing and sign errors; the coefficients below are the paper's Eq. 1 as I read it, and the code must check them against the published PDF before use; the NCAR NCL function page confirms the valid range and error). Tw = T·atan[0.151977(RH + 8.313659)^½] + atan(T + RH) − atan(RH − 1.676331) + 0.00391838·RH^1.5·atan(0.023101·RH) − 4.686035, T in °C, RH in %, angles in radians, at sea-level pressure. Valid for RH 5 to 99% and T -20 to 50 °C (not for cold and dry together); mean absolute error 0.28 °C, errors -1.0 to +0.6 °C.

**[67] Dimiceli VE, Piltz SF. Estimation of black globe temperature for calculation of the WBGT index. US National Weather Service (field tests Sept 2010).** Technical paper. Restates OSHA's WBGT definitions: without sun, WBGT = 0.7·natural wet bulb + 0.3·globe; with sun, 0.7·NWB + 0.2·globe + 0.1·dry bulb. A full globe estimate needs solar radiation, wind and cloud. Used only for the shade formula.

The Australian Bureau of Meteorology publishes a simpler shade WBGT approximation, but its explanation page blocks automated reading, so I could not read the formula and don't use it. Its observations page does say the shade WBGT assumes shade from direct sun and that afternoon sun adds a lot (up to 8 °C to its apparent temperature).

**[68] Apple. WeatherKit, HourWeather.** Developer documentation. Each forecast hour has `temperature`, `dewPoint`, `humidity`, `apparentTemperature`, `wind`, `cloudCover`, `uvIndex`, `isDaylight` and `date` (start of the hour). Open-Meteo's hourly API also gives `temperature_2m`, `dew_point_2m`, `relative_humidity_2m` (read on its docs page); no WBGT in either.

**Shade WBGT used by the spec.** WBGT_shade = 0.7·Tw + 0.3·T, with Tw from [66] and RH from [65]. Treating the natural wet bulb as the psychrometric wet bulb and the globe as the air temperature (true only in shade) is my simplification, not a validated estimate. In sun the true WBGT is higher, so the spec uses ACSM's most cautious column and region to make up for it, and says so.

## Treadmill

**[69] Jones AM, Doust JH. A 1% treadmill grade most accurately reflects the energetic cost of outdoor running. J Sports Sci, August 1996.** Peer-reviewed (abstract read on QxMD). Nine trained male runners used to treadmills; 6-minute runs at 2.92 to 5.0 m/s on a treadmill at 0 to 3% and on a level road. A 1% grade matched outdoor oxygen cost across that range; at 2.92 and 3.33 m/s road running did not differ from 0% or 1%. Small sample, one group.

**[70] Miller JR, Van Hooren B, Bishop C, Buckley JD, Willy RW, Fuller JT. A systematic review and meta-analysis of crossover studies comparing physiological, perceptual and performance measures between treadmill and overground running. Sports Med 2019;49(5):763–782.** Peer-reviewed systematic review, 34 studies, 468 adults (read on the Maastricht University repository). Submaximal VO2 did not differ overall (-0.28 ml/kg/min, moderate certainty), so the 1% convention was not clearly needed at submaximal speeds. Submaximal HR at 1%: +3 bpm on the treadmill (0 to 5), moderate certainty. Speed changed the HR gap: treadmill HR and RPE were higher at faster speeds and lower at slower ones, matching near 14 km/h at 0% and 11 km/h at 1%. Lactate was lower on the treadmill. Endurance performance was worse on the treadmill (SMD -0.50, low certainty). In one study, runners chose slower speeds on the treadmill at a fixed RPE. Heterogeneity high, samples small, treadmill familiarity rarely reported. Evidence: the effect is small on average and differs by person and speed, which is the case for learning a personal offset.

**[71] Van Hooren B, Fuller JT, Buckley JD, et al. Is motorized treadmill running biomechanically comparable to overground running? A systematic review and meta-analysis of cross-over studies. Sports Med 2020;50(4):785–813.** Peer-reviewed systematic review, 33 studies, 494 people (read on PMC). Most mechanics are similar; contact time 5 ms longer, foot strike angle about 10° flatter on the treadmill; stride length and frequency not different. Low or very low certainty. Physiology is in [70], not here. Used only to say cadence and stride on a treadmill are comparable enough to keep.

## What I couldn't read or find

- "Vihijalmsson" (or Vilhjálmsson) on marathon heat: not found under any spelling I tried.
- Maughan's marathon and heat papers: not read.
- The older ACSM position stand (2007): not read; the 2023 statement replaces it.
- PMC10041407 (the ACSM statement on PMC): blocked by a browser check; read from the KHSAA-hosted copy instead.
- The Bureau of Meteorology's WBGT explanation page: blocked to automated readers.
- Montain et al. 2007 [59]: abstract only. Ely et al. 2007 [58] and Jones and Doust [69]: abstracts only.
- El Helou's supplementary table S3 (per-level optima and losses): not read.

## Weak points

- The slow-down table is a coach's convention [62]. The race studies agree with its size at moderate heat, for groups, and nothing tests it in training.
- The shade WBGT is my simplification; it reads low in sun.
- ACSM's bands are for US regions and team sports; a runner's own acclimatization is unknown to the app.
- The personal model and the treadmill offset fit pace at HR. HR on any one day carries noise from sleep, hydration and cardiac drift; the minimum data and the bounds in the spec are heuristics chosen to keep one odd run from moving a target.
