# Mapping Pearson (1993) Gray–Scott Greek-letter regimes to (F,k) coordinates, practitioner names, and diffusion ratio

## Summary
Pearson’s 1993 Science paper presents a classification of Gray–Scott patterns labelled by Greek letters (α through μ) and shows these regions on a graphical phase map (Figure 3) with Figure 2 as the key, but the paper does not publish explicit numeric F or k boundary coordinates or an explicit diffusion-rate Du/Dv value in the sources provided here. [1], [4] Where later secondary or practitioner sources give representative (F,k) points for named visual regimes (spots, mitosis, worms, coral, waves, stripes), those points are recorded below and explicitly attributed to those sources rather than to numeric boundaries in Pearson. [5], [3] Simulation conditions used in Pearson’s numerical experiments (grid size, timestep, initial perturbation) are reported in the arXiv/Science text and are summarized below. [2]

## Machine-readable table — Pearson Greek-letter regimes (availability of numeric data)
(Note: Pearson’s primary figures show labeled regions but do not list numeric boundaries; the table reports what the evidence supports.)  
Columns: regime | F-range or boundary | k-range or boundary | representative (F,k) | Du/Dv
1. alpha | not specified in numeric form in Pearson Fig.2–3 (graphical region only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
2. beta | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
3. gamma | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
4. delta | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
5. epsilon | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
6. zeta | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
7. eta | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
8. theta | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
9. iota | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
10. kappa | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
11. lambda | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]
12. mu | not specified (graphical only) | not specified | not specified in Pearson; no practitioner (F,k) in provided findings | Du and Dv not reported in the provided Pearson sources [1], [4]

Sources for the table above: primary Pearson figures are graphical (Figures 2 and 3) and do not contain numeric F/k coordinate lists; secondary replotting and commentary exist but do not provide authoritative numeric boundaries in the provided findings. [1], [4], [3]

## Machine-readable table — Practitioner/common names and representative (F,k) example points (from practitioner sources)
Columns: practitioner name | representative (F,k) point(s) | source | uncertainty / note
1. Spots (pearls) | (F = 0.035, k = 0.065) | [5] | reported as practitioner example; not tied to a Pearson Greek label in provided findings
2. Mitosis (spot splitting) | (F = 0.028, k = 0.062) | [5] | practitioner example; mapping to Pearson label not specified in evidence
3. Worms (elongated mobile stripes) | (F = 0.078, k = 0.061) | [5] | practitioner example
4. Stripes / labyrinth (stationary maze-like stripes) | (F = 0.029, k = 0.057) | [5] | practitioner example
5. Coral / chaos (branching, tree-like growth) | (F = 0.082, k = 0.059) | [5] | practitioner example
6. Waves (spiral/target waves) | (F = 0.014, k = 0.054) | [5] | practitioner example

These practitioner (F,k) examples are drawn from a practitioner/summary source and are reported here as representative parameter points for visual regimes; the evidence does not show these points being mapped to Pearson’s Greek-letter labels within the primary Pearson figures. [5], [1]

## Key simulation conditions reported for Pearson’s runs (affecting reproducibility)
- Spatial mesh: 256 × 256 grid points (spot checks up to 1024 × 1024 produced no qualitative differences). [2]
- Time integration: forward Euler on finite-difference discretization; reported time step = 1 in Pearson’s simulations (spot checks with time step as small as 0.01 reported no qualitative differences). [2]
- Initial condition: system started in trivial state (U = 1, V = 0) with a 20 × 20 mesh-point central perturbation set to (U = 0.5, V = 0.25) and ±1% random noise to break symmetry. [2]
- Integration length: examples saved after long integration (one report: integration for 200,000 time steps). [2]

## Evidence gaps and uncertainties
- Pearson’s paper (Figures 2 and 3) displays Greek-letter regions graphically but does not publish numeric F or k boundary coordinates, nor does the provided evidence give explicit Du and Dv values or their ratio for the phase-diagram plots; therefore exact numeric boundaries and diffusion-rate values cannot be extracted from the provided primary sources alone. [1], [4]
- A secondary source (MROB) states it replotted/digitized Pearson’s Figure 3 with corrections, but the provided findings do not supply the numeric table, digitization method, resolution, or error estimate for that replot. [3]
- Practitioner example (F,k) points exist in the provided practitioner summary but the evidence does not connect those points to specific Greek-letter regions in Pearson’s figures. [5]
- Consequently, no new digitized boundary curves, numeric boundary equations, or Du/Dv values are reported here because the findings do not include those numeric extractions or methods. [3]

## Methods note
Pearson’s primary published phase diagrams (Figures 2–3) were inspected in the provided sources to determine whether numeric coordinates or diffusion rates were published; the findings show only graphical region labeling, not numeric boundaries, and therefore no new digitization or coordinate extraction was performed for this report. [1], [4] Practitioner representative (F,k) points were taken directly from the practitioner summary source cited above and are reported without conversion because they are already given in the standard non-dimensional Gray–Scott (F,k) notation in that source. [5] A secondary web replotter (MROB) reports having taken data from Pearson’s Figure 3, but the provided findings do not include the numeric results or digitization metadata needed to report precise boundaries or error estimates. [3]

## Conclusion
Pearson (1993) provides a graphical Greek-letter phase map for Gray–Scott patterns but does not publish numeric F/k boundaries or diffusion-rate ratios in the materials supplied here; practitioner sources supply representative (F,k) points for common visual regimes but do not link those points to Pearson’s Greek labels within the provided evidence. The primary missing items needed to fulfill the request fully are: (a) numeric coordinates for the region boundaries from Pearson’s Figure 3 or a documented digitization of that figure with method and error, and (b) the Du and Dv values (or Du/Dv) used for the phase diagram. These are not present in the supplied findings. [1], [2], [3], [5]

## Works Cited
[1] https://www3.nd.edu/~powers/pearson.pdf  
[2] https://arxiv.org/pdf/patt-sol/9304003  
[3] https://mrob.com/pub/comp/xmorphia/pearson-classes.html  
[4] https://math.univ-paris13.fr/~cuvelier/docs/Enseignements/MACS2/ProjetS8/19-20/Vauchelet/Sujet1/Pearson_GrayScott.pdf  
[5] https://mysimulator.uk/content/articles/gray-scott-reaction-diffusion.html  
[6] https://mrob.com/pub/comp/xmorphia/ogl/index.html  
[7] https://limbnet.embl.es/tutorials/gray-scott  
[8] https://researchgate.net/publication/6011915_Complex_Patterns_in_a_Simple_System
