# Gray–Scott critical nucleus: what perturbation size and amplitude trigger growth?

## Executive summary
The literature shows that the trivial Gray–Scott steady state (U=1, V=0) is linearly stable for typical positive parameter choices and that pattern formation in practice requires a localized, finite‑amplitude perturbation that places the system onto the unstable manifold of a nontrivial (localized) solution — the so‑called critical nucleus (a saddle in phase space). Explicit, widely‑applicable formulae for a 2D critical perturbation radius as a function of (Du, Dv, F, k) are not present in the surveyed literature; instead, studies report existence thresholds, bifurcation/instability curves, numerical continuation of localized branches, and a few asymptotic/numerical values for related splitting or spot‑existence thresholds. Practical numerical work therefore follows continuation plus direct simulation from parameterized localized blobs (top‑hat or Gaussian) and locates the saddle separating growth versus decay. [3], [14], [2], [13], [16], [8], [21], [23], [22], [9]

## 1. What the literature establishes (synthesis)
- Existence and stability structure: Gray–Scott admits the trivial fixed point (U=1,V=0) and, depending on F and k, two nontrivial fixed points; localized patterns typically appear beyond bifurcation/existence curves and require finite (not infinitesimal) seeds to form. Numerical studies routinely start from localized, large‑amplitude perturbations to nucleate spots and rings because the homogeneous state is linearly stable in the parameter regimes considered. [1], [3]

- Critical nucleus as a saddle / nucleation picture: The object separating decay from growth is described as a dissipative soliton or saddle solution (critical nucleus) whose stable manifold is codimension‑one; crossing that manifold leads to growth into a persistent localized state (spot, replicated spots, or patterned state). On bounded domains (torus) the relationship between nucleus size and excitation threshold can be nonmonotone and control or geometry can shift thresholds. [14], [16]

- Bifurcations and parameter dependence: Analyses show multiple instability mechanisms (spot self‑replication, oscillatory amplitude instabilities, competition between spots) and parameter‑dependent transitions (e.g., Hopf can change between sub‑ and supercritical behavior as feed parameter A varies), so whether a small blob grows depends qualitatively on where (Du, Dv, F, k) sit relative to these bifurcation curves. Asymptotic studies produce existence and splitting thresholds (example: a computed splitting threshold Σ2 ≈ 4.31 in one computation of spot‑replication criteria). Several authors derive scalings for spike amplitude and eigenvalues involving diffusion and small parameters, but no universal closed‑form radius law for 2D Gray–Scott appears in the surveyed sources. [2], [8], [13], [12]

## 2. Quantitative thresholds and scalings — what is available
- Explicit numeric radii: No paper in the provided evidence gives a universal 2D critical perturbation radius expressed as a simple function of (Du, Dv, F, k). The literature instead produces:
  - Existence/bifurcation boundaries (parameter curves where nontrivial steady states appear or lose/gain stability) that delimit regimes where nucleation is possible. [1], [3]
  - Numerically computed spot‑splitting/existence thresholds for related source‑strength parameters (example: Σ2 ≈ 4.31 for a computed splitting threshold in a spike stability study). That number characterizes replication instabilities rather than a single‑parameter critical radius across all (Du,Dv,F,k). [2]
  - Qualitative/parametric trends: larger critical nuclei correspond to lower excitation thresholds in some geometries and the torus geometry can invert that dependence in others (geometry and BC matter). [14]

- Scalings: Asymptotic analyses report scalings linking spike amplitude and certain thresholds to diffusion and small parameters (e.g., amplitude ∼ √D times functions of spacing or source strength) and show that stability thresholds depend sensitively on D and inter‑spot spacing via Green’s‑function interactions; however, a simple length scale like “critical radius ∼ sqrt(D/λ)” is not given in the evidence. [2], [13]

## 3. Mechanistic explanation: why single‑cell perturbations usually decay while blobs can grow
- Linear stability and basin‑of‑attraction picture: The homogeneous state is linearly stable in the commonly studied parameter regimes; therefore infinitesimal or very small, spatially incoherent perturbations project onto decaying linear modes and relax back to (1,0). Only perturbations that place the solution outside the trivial basin and sufficiently close to the unstable manifold of a localized steady state (the saddle critical nucleus) can evolve toward a growing pattern. This is why the literature emphasizes large‑amplitude, spatially coherent seeds (blobs) rather than single‑grid‑cell noise. [3], [14]

- Role of reaction vs diffusion: Diffusion smooths small‑scale perturbations faster than local reaction terms can amplify them when the homogeneous state is stable; spatially extended blobs concentrate enough integrated reaction “drive” so that nonlinear autocatalysis (UV^2) overcomes diffusion loss and moves the field toward the localized attractor. Asymptotic spike analyses show diffusion coefficients and spike source strength set the thresholds for instabilities and replication. [13], [2]

- Discrete/numerical effects: The surveyed literature stresses careful numerical methods and continuation to resolve saddle branches; time‑step and spatial discretization errors are tracked in numerical convergence studies, but explicit, general prescriptions on the minimum number of grid points per critical radius are not provided in the available evidence — this is an identified gap. [21], [9]

## 4. Reproducible numerical protocol (literature‑aligned recommendations and known practices)
- Boundary conditions and domain sizes used in examples: homogeneous Neumann (no‑flux) boundary conditions are common for Gray–Scott studies; example domains include (0,2.5)^2 and small square domains used in literature, while datasets and 1D studies use periodic or fixed Dirichlet choices in specific experiments — choose BC consistent with the physical question (Neumann is typical). [22], [21], [23], [19]

- Perturbation shapes actually used: literature and datasets commonly use localized large‑amplitude blobs: circular top‑hat (sharp) blobs, Gaussians, or clusters of Gaussians; numerical continuation and simulations typically vary amplitude (ΔV) and radius until the seeded state either relaxes to (1,0) or grows into a localized spot or pattern. [3], [23]

- Algorithms for threshold identification: continuation methods (pseudo‑arclength continuation) are used to follow steady localized branches and locate saddle folds; direct time‑integration from parameterized blobs is used to test whether a seed grows or decays. These are the documented numerical paths to locate critical nuclei in the literature. [9], [3]

- Convergence checks shown in literature: time‑step convergence studies with successively refined Δt and error reporting are documented; similar spatial convergence tests are necessary though explicit Δx/points‑per‑radius rules are not present in the reviewed findings. Reported examples of time‑step refinement and error reduction illustrate good practice. [21]

- What to report for comparability: when publishing thresholds, report (Du, Dv, F, k), domain size & BC, perturbation family (function), amplitude definition (ΔV peak or integrated norm), grid spacing Δx, Δt, and whether continuation or time‑integration was used. The dataset examples and convergence studies demonstrate this reporting practice. [23], [21]

## 5. Representative parameter values (what the literature provides)
- Pattern‑producing sample parameter sets (from a curated simulation dataset): example pairs (f,k) and diffusion values used for producing spot/maze/worm patterns include f=0.03, k=0.062 with Du=2e‑5, Dv=1e‑5 (spots); other pattern regimes in the dataset use f in 0.014–0.098 and k ≈ 0.051–0.065 — these are useful starting points for experimentation, though explicit critical radii for these sets are not reported in the evidence. [23]

- Bifurcation/existence lines: an algebraic bifurcation line reported in one summary locates nontrivial fixed‑point existence beyond F = 4(F+k)^2 (reported as a bifurcation condition in a student project summary); use such curves as guides to locate subcritical regimes where nucleation is relevant. [1]

- Computed splitting threshold example: a spot‑splitting threshold Σ2 ≈ 4.31 appears in a spike instability computation; this is an example of the kind of numerical threshold available in the asymptotic/spike literature (not a direct 2D critical radius value). [2]

## 6. Limitations, open problems, and evidence gaps
- Missing in the supplied literature: direct tables or closed‑form formulae giving a 2D critical perturbation radius R_c = R_c(Du, Dv, F, k) (or amplitude–radius manifolds) are not present. There is no explicit, general recommendation for Δx relative to R_c (minimum points per critical radius) in the reviewed sources. No universal simulation time cutoff for declaring growth vs decay is specified in the evidence. [3], [2], [21]

- Regimes where a scalar R_c is inadequate: near codimension‑two points (Turing–Hopf), near Hopf sub↔supercritical transitions, or when multiple unstable modes interact, the notion of a single scalar critical radius breaks down and more elaborate bifurcation/phase‑space descriptions (homoclinic snaking, multi‑pulse branches) are required. The literature documents such complexities and the need for continuation and asymptotic analysis there. [6], [8], [16]

## Practical next steps (based on the literature)
1. Choose a parameter set (report Du, Dv, F, k explicitly; sample sets in [23]).  
2. Use pseudo‑arclength continuation to locate localized steady branches and saddle folds where possible [9].  
3. In direct simulations (Neumann BC typical), seed circular top‑hat and Gaussian V perturbations, sweeping radius and peak ΔV; follow each seed long enough to see relaxation or approach to a localized attractor (no literature consensus on time cutoff — treat this as an experimental convergence parameter) [3], [21], [23].  
4. Perform Δx and Δt refinement studies (report convergence) before quoting a critical radius; use the time‑step convergence practice shown in [21] as a template.  

Evidence gaps that further work should close include systematic computation of R_c(Du,Dv,F,k) in 2D with grid‑convergence studies, and explicit rules for minimal Δx resolution per R_c.

## Works Cited
[1] https://itp.uni-frankfurt.de/~gros/StudentProjects/Projects_2020/projekt_schulz_kaefer  
[2] https://personal.math.ubc.ca/~ward/papers/thesis_wanchen.pdf  
[3] https://pub.math.leidenuniv.nl/~doelmana/HP_PUB/DKZ.pdf  
[4] https://iopscience.iop.org/article/10.1088/1367-2630/16/5/053010/pdf  
[5] https://personal.math.ubc.ca/~jcwei/HopfBifur-GS-Sch-2018-10-15.pdf  
[6] https://mathstat.dal.ca/~tzou/TzouMaBaylissMatkowskyVolpert_HomoclinicSnakingNearCodimensionTwoTuringHopfBifurcationPointBrusselatorModel%282013%29.pdf  
[7] https://irep.ntu.ac.uk/id/eprint/45425/1/1511706_Nelson.pdf  
[8] https://mdpi.com/2079-8954/9/4/71  
[9] https://par.nsf.gov/servlets/purl/10354146  
[10] https://polymathic-ai.org/the_well/datasets/gray_scott_reaction_diffusion
