# Racing-coach literature: researched starter pack

Research date: **30 September 2026**. Scope: video-only coaching for *The Crew Motorfest* on PS4 Pro.

## Recommendation

We have enough free material to build and test a first literature-assisted annotation prompt. Start with the Driver61 tutorials and Ross Bentley's freely available material below. If obtaining one paid book, prioritize **Ultimate Speed Secrets**; add **Going Faster!** for a second instructional perspective. Do not buy an engineering textbook before testing whether the basic annotation workflow is useful.

These are recommendations for this project's needs, not a claim that every candidate book has been read or that the sources prove the proposed model will work. Full paid books were not accessed. The reference pack is **draft, not expert-approved or Motorfest-validated**.

## What was actually collected

- [Source catalog](../Training/guidance/literature/source_catalog.json): 17 records distinguishing reviewed material, book metadata, and further-reading leads.
- [Concept cards](../Training/guidance/literature/concept_cards.jsonl): nine short, independently worded literature summaries and three explicitly identified project safeguards.
- One author-hosted free ebook downloaded locally, with its checksum recorded. The original lives under ignored `data/guidance/literature/raw/`, not in the publishable reference pack.
- This report linked from the [implementation plan](GUIDANCE_MODEL_IMPLEMENTATION.md#61-build-the-reference-pack).

“Extracted” here means selecting and paraphrasing relevant concepts with provenance, not copying whole articles or chapters. Embedded tutorial videos were not reviewed. No gameplay was uploaded, no annotation experiment was run, and no model was trained as part of this research.

## Free material reviewed

| ID | Source | Useful contribution and important boundary |
| --- | --- | --- |
| L01 | Scott Mansell / Driver61, [The 6 Phases of a Corner](https://driver61.com/uni/corner-phases/) | Vocabulary for the sequence through a corner. Its pedal-oriented phases are not all directly observable from our video. |
| L02 | Scott Mansell / Driver61, [How to Drive the Perfect Racing Line](https://driver61.com/uni/racing-line/) | Relates entry, apex and exit choices to the corner and what follows. Does not justify one universal “best line.” |
| L03 | Scott Mansell / Driver61, [The Ultimate Guide to Braking for Fast Lap Times](https://driver61.com/uni/braking/) | Separates brake application, modulation and release. Does not provide Motorfest braking thresholds or visible pedal measurements. |
| L04 | Scott Mansell / Driver61, [How to Trail Brake](https://driver61.com/uni/trail-braking/) | Explains overlapping braking and turning as a conditional technique. Do not prescribe it for every corner. |
| L05 | Scott Mansell / Driver61, [How to Find Grip on the Race Track](https://driver61.com/uni/grip/) | Introduces competing longitudinal and lateral tire demands. Treat the simplified grip budget qualitatively. |
| L06 | Scott Mansell / Driver61, [Maximising the Exit Phase](https://driver61.com/uni/corner-exit/) | Connects opening the trajectory with increasing acceleration. An apparent corner exit does not establish that traffic or the road ahead is clear. |
| L07 | Scott Mansell / Driver61, [How Improving your Vision on Track Improves Lap Times](https://driver61.com/uni/vision/) | Anticipating the next reference point informs cue timing. Screen capture cannot reveal the player's gaze. |
| L08 | Ross Bentley, [Practicing trail braking and brake release](https://speedsecrets.com/q-how-should-i-practice-and-get-better-at-trail-braking-and-my-brake-release/) | Brake-release timing and rate require deliberate practice and vary with the situation. Supports allowing justified action windows rather than a single assumed timestamp. |
| L09 | Ross Bentley, [Performance Driving Illustrated](https://speedsecrets.com/product/performance-driving-illustrated/) | Free illustrated reference covering load transfer, grip and line tradeoffs. Selected sections were read; see the page map below. |

### Downloaded ebook: reading map

The downloaded *Performance Driving Illustrated* contains 46 PDF pages. Its internal version is **1.0, 2-15-16**, with a 2015 copyright; the website's 2024 file path is not an edition date. Page references below use **printed page numbers**, with PDF page numbers in parentheses.

- **7–16 (PDF 9–18):** load transfer, handling balance, tire slip and combined demands.
- **17–23 (PDF 19–25):** trajectory choices and corner-to-corner tradeoffs.
- **31–33 (PDF 33–35):** the interaction of line, braking release and steering.

These sections were text-reviewed; selected diagram pages were also visually checked. The book's illustrative traction units are not measured parameters for our simulator. Explanations of understeer/oversteer do not make those states reliably identifiable from arbitrary gameplay frames.

Get your own copy from the [author's official PDF](https://speedsecrets.com/wp-content/uploads/2024/02/Performance-Driving-Illustrated-2-23-24.pdf). Free access does not mean public-domain content or permission to redistribute the book. Keep the original local and share source links and concise original notes instead.

## Supporting research—not coaching labels

**L10 — Bosch, [Electronic stability program](https://www.bosch-mobility.com/en/solutions/driving-safety/electronic-stability-program/).** Its operating explanation describes comparing intended and actual vehicle motion using steering-angle, wheel-speed, yaw-rate and lateral-acceleration information. Our inference: these signals are a useful checklist of what screen-only analysis does not directly measure. This is not proof that vision inference is impossible; it is a reason not to label steering intent, tire slip or handling imbalance as observed facts without a separately validated estimator.

**R01 — Lee et al., [A Champion-level Vision-based Reinforcement Learning Agent for Competitive Racing in Gran Turismo 7](https://arxiv.org/html/2504.09021v1), 2025.** The abstract and observation/training-method sections were reviewed. Despite “vision-based” in the title, the agent also receives vehicle information such as velocity, acceleration and controls, and training uses privileged information. It is useful context for temporal perception and training/deployment input distinctions—not evidence that a screenshot-only Motorfest coach or a literature-assisted VLM teacher is already solved. Do not use this paper as ground-truth driving advice.

## Paid books: what to obtain, in order

| Priority | Book | Why I would choose it for this project | What was verified |
| --- | --- | --- | --- |
| 1 | Ross Bentley, **Ultimate Speed Secrets: The Complete Guide to High-Performance and Race Driving** — [author's books page](https://speedsecrets.com/books/) | Broad practical reference to deepen the annotation handbook and explain coaching decisions. The first book I would ask you to obtain. | Author's description; not the full book. |
| 2 | Carl Lopez / Skip Barber Racing School, **Going Faster! Mastering the Art of Race Driving** — [book catalog](https://books.google.com/books/about/Going_Faster.html?id=yLLcIwAACAAJ) | A second structured instructional reference, useful for checking where explanations agree or require different conditions. | Bibliographic/catalog description; not the full book. |
| 3, optional | William F. Milliken and Douglas L. Milliken, **Race Car Vehicle Dynamics** — [authors' company](https://www.millikenresearch.com/rcvd.html) | Deeper tire and vehicle-dynamics theory if we later build calibrated physics models. It cannot supply hidden Motorfest parameters by itself. | Authors' overview and topic listing; not the full book. |
| Later, optional | Ross Bentley, **Speed Secrets 4: Engineering the Driver** — [author's books page](https://speedsecrets.com/books/) | More relevant when refining how the coach teaches and delivers feedback. | Author's description; not the full book. |

Purchase is **not a prerequisite** for the first pilot. A lawful ebook or permitted excerpts supplied by the user can be reviewed later; record the edition and page numbers before adding new concepts. This is not a request to source unauthorized copies.

## Additional free leads—not extracted into the pack

- **Q01:** IIT Madras / Dr. R. Krishnakumar, [NPTEL Vehicle Dynamics](https://nptel.ac.in/courses/107106080). Course listing/syllabus identified; lectures not reviewed. A potential free route into the engineering background if the basic tutorials leave a specific question unresolved.
- **Q02:** Ross Bentley, [How to Win at Sim Racing](https://speedsecrets.com/product/how-to-win-at-sim-racing/). Listed as free with a signup flow; ebook contents not obtained or reviewed. No contact details were submitted. This is optional, not a blocker.

## How this becomes useful supervision

The following are **project design decisions**, not claims that the sources have validated our system:

1. Use the source catalog and concept cards as a small, auditable context pack. Include only concepts relevant to the requested label and preserve their source IDs.
2. Ask the teacher for visible observations first: turn direction, coarse phase and readable HUD speed. Keep inferred intent, diagnosis and recommended action in separate fields with evidence and uncertainty.
3. Begin with coarse phase labels such as approach/entry/apex-region/exit. A reviewer must establish whether these can be distinguished consistently in the supported camera view. Do not force pedal-oriented labels onto video that cannot support them.
4. Never manufacture a target speed, braking distance, friction coefficient, pedal pressure or exact steering angle from a general principle. Missing observations remain unknown; they do not become zero.
5. Give humans the same causal clip the live system could have seen. Preserve future outcomes separately; do not justify an earlier cue using later frames.
6. Compare the same teacher **with versus without** these notes against independently produced human labels. Keep the context only if it improves the relevant fields or reduces correction effort without increasing serious errors.

Before real-time action guidance, Motorfest-specific recordings and qualified review must establish which recommendations are supportable. The literature supplies concepts and constraints; it does **not** supply ready-made correct actions for each gameplay frame.

### Deliberately excluded from the teacher pack

- Universal prescriptions such as “always trail brake,” “always use a late apex,” or “always accelerate at corner exit.”
- Real-car numerical examples copied into game-specific target speeds, braking thresholds or tire parameters.
- Unqualified ABS comparisons, track-limit/curb advice, and illustrative grip percentages treated as universal rules.
- A second model agreeing with the teacher as a substitute for independent label review.

## Completion status

**Done:** targeted literature search, scoped source review, one lawful public PDF download, concise concept extraction, provenance and access-status records.

**Free-source working pack prepared, 30 September 2026:** the [annotation pilot pack](../Training/guidance/teacher/README.md) now includes a draft observable-label handbook, shared teacher prompt, proposed paired experiment settings, synthetic output example and human-review protocol. It uses only the existing free reference notes. It is a manual-ready specification, not a running teacher pipeline or a completed evaluation.

**Still required:** expert review of the cards, any paid-book reading, gameplay annotation, the literature/no-literature comparison, and all model training and live validation. No claims of annotation accuracy or coaching effectiveness follow from collecting this pack.
