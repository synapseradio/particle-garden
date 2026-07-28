# Research reports

Cited literature syntheses gathered while designing the one-world merge. They exist so the findings
that shaped the design outlive the session that produced them, and so a later reader can check a
decision against its evidence rather than taking it on trust.

| File | Answers |
|---|---|
| `ignition-threshold.md` | What perturbation escapes Gray-Scott's trivial steady state, and why isolated cells decay while coherent blobs grow |
| `pearson-map.md` | Whether Pearson (1993) publishes numeric (F,k) regime boundaries, and what practitioner coordinates exist instead |
| `chemotaxis-stability.md` | When agents that both deposit into and follow a chemical gradient aggregate stably versus collapse |
| `alife-research.md` | Architectures for coupling continuous fields to particle agents, and what keeps such systems evolving indefinitely |
| `artistic-research.md` | Making a toroidal world feel boundless, and making simulation feel painterly rather than clinical |

## The four findings that decided the design

**The trivial state is provably stable at our defaults.** Gray-Scott's nontrivial fixed points exist
only where `F ≥ 4(F+k)²`. Substituting `UV² = (F+k)V` into `F(1-U) = UV²` gives
`(F+k)V² − FV + F(F+k) = 0`, whose discriminant is `F(F − 4(F+k)²)`. At the shipped defaults
`F = 0.030`, `k = 0.062`, `4(F+k)² = 0.0339 > 0.030`.

This is the design's foundation rather than a problem with it. In this regime a pattern **cannot**
arise from the uniform state at all — it must be nucleated by a supercritical perturbation. Keeping
the default here is what makes the field a genuine record of life: no colony, no pattern, ever.
`field_core.nim:80-84` observed this empirically without knowing the reason.

**Ignition is a map, not a yes/no.** MROB's corrected replot of Pearson's Figure 3 notes that type δ
includes true Turing patterns arising "from a starting pattern that is all blue, with arbitrarily
small noise", while Turing-*similar* regions cannot start from uniform at all. The `F = 4(F+k)²`
curve is the border between them, and it is worth showing the user.

**No closed-form critical radius exists.** The literature offers bifurcation curves and continuation
methods but no universal 2D formula relating critical radius to (Du, Dv, F, k). The documented
practice is to sweep top-hat and Gaussian seeds over radius and amplitude — which is exactly what the
native ignition sweep does. That sweep is the field's own method, not a workaround.

**Up-gradient motion is the dangerous sign.** Keller-Segel gives the 2D collapse threshold
`χ·M > 8π` for positive chemosensitivity — agents climbing their own deposited gradient. Moving down
the gradient is stabilizing. This independently validates the caution already recorded at
`config_ranges.nim:104-108`.

## Sources

- Pearson, J.E. (1993), *Complex Patterns in a Simple System*, Science 261(5118), 189-192.
  Preprint: https://arxiv.org/pdf/patt-sol/9304003
- MROB, *Pearson's Classification (Extended) of Gray-Scott System Parameter Values*:
  https://mrob.com/pub/comp/xmorphia/pearson-classes.html
- Practitioner regime coordinates:
  https://mysimulator.uk/content/articles/gray-scott-reaction-diffusion.html

Each report carries its own full citation list.
