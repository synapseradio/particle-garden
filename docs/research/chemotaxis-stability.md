# Stability bounds for chemotaxis coupled to reaction–diffusion (Gray–Scott) fields

## Executive summary
- In classical continuum Keller–Segel (KS) formulations the main actionable blow-up criterion in two spatial dimensions is χ·M > 8π (parabolic–elliptic, no damping): when chemosensitivity χ (positive, up‑gradient motion) times total mass M exceeds 8π, finite‑time chemotactic collapse can occur; χ·M ≤ 8π guarantees global solutions in that idealized setting [1].  
- For reaction–diffusion coupling (e.g., Gray–Scott acting as chemo‑field), linear stability of the homogeneous state gives a practical inequality of the form χ·(α/β) < D·π^2/L^2: increasing chemo‑decay β, reducing χ, increasing agent motility D (D_n) or reducing domain size L stabilizes against aggregation [4].  
- Reaction–diffusion + chemotaxis coupling typically enlarges the patterning region (so moderate χ can promote patterns rather than collapse) but large positive χ still risks loss of regularity and blow‑up; logistic/decay terms and porous‑medium / nonlinear diffusion can restore global existence [6], [8], [10].

## 1. Models considered and how they relate
- Keller–Segel (continuum) core forms: parabolic–parabolic (density n evolving diffusive + chemotactic drift, coupled to time‑dependent chemo c) and parabolic–elliptic quasi‑static (c given by Poisson/elliptic solve). These are the canonical frameworks for studying chemotactic collapse and patterning [2].  
- Particle–PDE hybrid: discrete agents deposit chemo (pointwise or smoothed) while agent velocities include drift proportional to ±χ ∇c; the continuum KS limit is recovered formally when agent number is large and deposit kernels shrink to δ (classical derivations and user guides discuss this continuum–particle link) [8].  
- Gray–Scott (GS) RD coupling: GS uses two species u,v with Du,Dv and reaction terms F(1−u) − uv^2 and uv^2 − (F+k)v (canonical equations summarized in standard notes); mapping a GS species to an effective chemo–field proceeds by identifying D_c = diffusion of the chosen species and linearizing its local production/decay to read off effective production α and decay β near the homogeneous equilibrium (so the chemotactic subsystem can be written as ∂_t v ≈ D_v Δv + α u − β v for linear stability analysis) [5], [4].

(References for model forms and GS equations are given in the Sources list below.) [2], [5], [4]

## 2. Key dimensionless groups and practical thresholds
- Primary dimensionless groups (useful for thresholds): χ (signed chemosensitivity), nondimensional mass M (total agent mass/number), Péclet‑like group χ·α/(D_n·β) (couples chemotaxis strength, chemo production/decay, and agent motility), and domain scale number L (via eigenvalues ~π^2/L^2). These combine into practical inequalities below; the literature frames blow‑up bounds in these combined forms [4], [3], [1].  
- 2D critical‑mass (parabolic–elliptic, no damping): global existence iff χ·M ≤ 8π; blow‑up possible when χ·M > 8π (this is the canonical sharp threshold in the idealized 2‑D KS model) [1].  
- Linearized chemotaxis–reaction stability (practical test): a homogeneous steady state is linearly stable if
  χ · (α/β) < D · π^2 / L^2,
  where D is agent diffusivity (D_n), α/β is steady chemo gain per agent, and L is domain length scale (eigenmode k=1). If this inequality fails, chemosensitive advection can destabilize the homogeneous state and drive aggregation or patterning on the corresponding length scale [4].  
- Higher dimensions and nonlinear diffusion: in d ≥ 3, porous‑medium or degenerate diffusion can alter thresholds and a sharp critical mass M_c exists that depends on dimension, χ_0, D_0 and β_0; for certain critical nonlinear diffusion scalings one obtains a sensitivity threshold separating global existence from finite‑time blow‑up [10], [3].

## 3. Blow‑up vs boundedness — rigorous/semirigorous criteria
- Positive chemosensitivity (χ > 0, movement up own deposit) provides positive feedback and is the collapse‑producing sign in KS theory; the 2‑D χ·M > 8π criterion is the canonical collapse condition in the parabolic–elliptic case [1].  
- Adding chemo decay (β>0), logistic damping on agents, or nonlinear (porous‑medium) diffusion can restore global existence and raise/replace the naive 8π threshold; several rigorous works show global existence for subcritical mass or small initial norms and produce blow‑up examples for supercritical parameters [3], [10], [8].  
- Negative chemosensitivity (χ < 0, movement down gradients) is stabilizing: dispersion relations change sign and chemotactic terms act like additional effective diffusion (suppression of aggregation), so linear stability criteria invert sign and instabilities are generally suppressed (this sign flip is explicit in linearized eigenvalue conditions) [4], [6].

## 4. Linear stability and Gray–Scott + chemotaxis
- Linearization methodology (additive perturbations e^{λt + ik·x}) and Jacobian–diffusion matrices from reaction terms give dispersion relations that predict onset wavenumbers and growth rates; this yields analytic thresholds for patterning vs stability and indicates how χ shifts/expands pattern regions relative to pure Turing RD [5], [6].  
- Practically: treat one GS species v as chemo; linearize the GS reaction terms at (u*,v*) to identify α and β in the chemotaxis subsystem, then apply the inequality χ(α/β) < D·π^2/L^2 as a conservative stability bound for the lowest nonzero mode [4], [5].

## 5. Particle implementations: pragmatic parameter guidance
- Continuum thresholds translate approximately to particle systems when deposit kernels are smooth and N is large, but discreteness and finite‑kernel widths matter: finite N can trigger noise‑driven aggregation even below continuum critical mass and pointwise deposits may accelerate collapse relative to smoothed kernels; user guides recommend smoothing kernels and finite sensing radii to approach continuum behaviour [8].  
- Safe, practical rules of thumb (conservative, derived from linearized inequality and continuum thresholds): (a) choose χ small enough that χ·(α/β) << D_n·π^2/L^2 for your domain L; (b) ensure chemo decay β is not too small — increasing β reduces effective gain α/β; (c) include agent-level stochastic motility and deposit smoothing with kernel radius comparable to grid spacing. A low‑chemotaxis example used in coupled Turing‑chemotaxis simulations is χ = 4 (reported as a "low" value in one numerical study) and serves as a starting test point for patterning without immediate catastrophic collapse in those models [7], [6].  
- Regularization strategies known to restore global existence in continuum theory and recommended for particle models: logistic‑type damping or superlinear degradation of agents/chemo, bounded (saturating) sensitivity functions, fast chemo decay, kernel smoothing of deposits, or nonlinear diffusion; several rigorous works establish existence/boundedness under such terms [8], [9].

## 6. Numerical experiments and diagnostics (recommended)
- Linear‑stability sweep: compute dispersion relation from linearization (method in standard notes) and verify predicted unstable bands; confirm with PDE simulations and with hybrid particle–PDE runs using particle‑in‑cell or smoothed‑particle deposition to compare thresholds [5], [4].  
- Diagnostics: track max agent density (for blow‑up), mass moments, power spectra (dominant wavelengths), time to first peak and growth rates (compare to linear λ(k)), and dependence on kernel width and N. Use no‑flux and periodic domains to test boundary effects; note that thresholds scale with L through π^2/L^2 in the linear inequality [4].  
- Start parameter sweeps from the conservative inequality χ(α/β) = 0.1·(D_n π^2/L^2) up to χ(α/β) ≈ (D_n π^2/L^2) to map transition from stable patterns → faster patterning → high‑contrast aggregation → potential blow‑up; verify collapse by unbounded growth of max density for continuum PDEs or formation of extremely sharp peaks in particle systems [6], [4], [7].

## Evidence gaps
- The provided evidence does not give explicit quantitative bounds for how wide a smoothing kernel or how strong a saturation of χ must be in particle models to prevent blow‑up; only qualitative and model‑dependent results are reported.  
- Explicit mapping formulas from a generic Gray–Scott parameter set (F,k,Du,Dv) to precise effective α,β values for the chemo linearization are not supplied in the findings; linearization procedures are indicated but full closed‑form mappings are model‑specific and require further calculation for each equilibrium [5], [4].

## Practical takeaways
- Use the 2‑D KS benchmark χ·M ≤ 8π as a conservative collapse check for continuum‑like systems without decay [1].  
- For coupled RD fields (including Gray–Scott), enforce χ·(α/β) < D_n·π^2/L^2 (computed from linearization at the homogeneous state) as a practical stability margin; if mapping to particle models, add deposit smoothing and agent diffusion to approximate continuum safe regimes [4], [5], [8].  
- If patterns are desired but collapse must be avoided, operate in the intermediate regime where chemotaxis enlarges the patterning region but χ remains below the conservative linear stability bound and include logistic or decay terms as safety nets [6], [9].

## Works Cited
[1] https://ceremade.dauphine.fr/~dolbeaul/Preprints/Fichiers/Keller-Segel-30.pdf  
[2] https://link.springer.com/article/10.1007/s00285-008-0201-3  
[3] https://tse-fr.eu/sites/default/files/medias/doc/by/blanchet/dec_2010/bl2.pdf  
[4] https://arxiv.org/html/2603.04931v1  
[5] https://math.libretexts.org/Bookshelves/Scientific_Computing_Simulations_and_Modeling/Introduction_to_the_Modeling_and_Analysis_of_Complex_Systems_(Sayama)/14%3A_Continuous_Field_Models_II__Analysis/14.04%3A_Linear_Stability_Analysis_of_Reaction-Diffusion_Systems  
[6] https://link.springer.com/article/10.1007/s11538-023-01225-5  
[7] https://pmc.ncbi.nlm.nih.gov/articles/PMC10692013  
[8] https://aimsciences.org/article/doi/10.3934/dcdsb.2022075  
[9] https://vcalvez.perso.math.cnrs.fr/publis/Calvez-Corrias-2008.pdf  
[10] https://link.springer.com/article/10.1007/s00526-008-0200-7
