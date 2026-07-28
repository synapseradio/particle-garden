# Making a toroidal (edge‑wrapping) generative world feel boundless, non‑repeating and painterly

## Summary
Practical success combines three threads: (A) algorithmic strategies that remove tiling seams and introduce aperiodicity (domain warping, periodic/phase‑shifted noise, patch/texture synthesis, Wang tiles, blue‑noise placement); (B) perceptual/artistic techniques (multi‑timescale camera drift, layered parallax with independent wrap behavior, scale/contrast/focus cues, stochastic micro‑variation); and (C) temporal controls that preserve coherence while avoiding frozen repetition (temporal decorrelation, ping‑pong history, flow advection and controlled blending). The sections below synthesize actionable algorithms, GPU/CPU patterns, parameter suggestions (only where evidence supports values), UI mappings, evaluation heuristics, and concrete recipes.

## 1. Seamless, non‑repeating toroidal wrapping — algorithms & implementation patterns
- Domain warping + FBM: Build tiled/periodic base noise (use periodic variants of Perlin/Simplex) and then domain‑warp with nested FBM chains (fbm(p + fbm(p + fbm(p)))) using a decorrelating rotation mat2(0.80,0.60,-0.60,0.80) and stable hash functions for jitter; this reduces grid‑like repetition while staying GPU friendly in fragment shaders [1].  
- Periodic noise primitives: Use the webgl‑noise library that provides periodic (tiled) Simplex/Perlin variants; those are the building blocks for exact wrap behavior on the torus [2], [19].  
- Patch‑based / exemplar texture synthesis on a torus: Offline or GPU‑assisted patch quilting / search (Efros & Freeman style) can generate large, seamless toroidal textures by treating the exemplar as toroidal during synthesis and adding controlled jitter per pyramid level for variation [3].  
- Wang / tile sets for non‑periodic assembly: Wang tiles enable assembling very large non‑periodic textures without visible edge mismatches — a useful runtime tiling strategy when memory is limited [18], [4].  
- Blue‑noise / Poisson‑disk placement for discrete elements: For object placement that avoids clustering or aliasing, use Poisson‑disk / blue‑noise sampling to distribute landmarks uniformly without low‑frequency spikes; GPU/parallel methods exist for real‑time rates if needed [5], [6].

Implementation notes and tradeoffs:
- Real‑time: favor periodic noise + domain‑warping in fragment shaders (GLSL/WebGL) and lightweight FBM chains for speed [1],[2]. Use compute shaders or VFX Graph for large particle sets when available [17].  
- Offline / high‑quality: use example‑based patch synthesis or the texture‑synthesis pyramid (quilt/cut) for high‑fidelity, aperiodic surfaces [3].  
- Projection vs flat displays: for omnidirectional/equirectangular projection, use mapping-aware shaders (equirectangular coordinate computation) to avoid seams on spherical projections [16]. For flat toroidal displays, periodic noise + tileless texture synthesis suffice.

## 2. Perceptual tricks to suggest boundlessness
- Camera drift and multi‑timescale motion: slow randomized drift plus very slow large‑scale offset (multi‑timescale motion) prevent lock‑in to a repeating viewpoint; coupling these with per‑layer independent phase offsets helps break global repetition (evidence supports multi‑timescale Turing/reaction patterns producing complex structure) [10].  
- Parallax layering and independent wrap behavior: render foreground/midground/background as independent wrapped layers with different effective wrap speeds and independent phase/seed; make near layers obey local object‑scale parallax while far layers use scale‑free scrolling to avoid alignment cues that reveal tiling [14],[22].  
- Avoid repeating landmarks: combine blue‑noise placement of salient elements with procedurally varied local micro‑features (stochastic brush/noise overlays and phase‑shifted texture instances) to ensure no identical landmark reappears frequently [5],[6].

## 3. Temporal strategies: avoiding visible repetition over time
- Temporal decorrelation and phase shifts: give layers independent phase offsets and different wrap periods; avoid global synchronous loops by adding small randomized frequency offsets per layer (use seeded randomness to preserve reproducibility when desired).  
- Preserve coherence without freezing: blend current frame with reprojected history (TAA‑style exponential moving average fn = α·s + (1−α)·history(π(p))), but validate/rectify history to avoid ghosting; choose α to trade responsiveness vs stability [7].  
- Frame‑history & ping‑pong buffers: use ping‑pong buffers for advection and trails (store velocity/particle state across frames) and avoid read/write hazards by alternating buffers [8],[14].

## 4. Making simulations feel alive and painterly
- Motifs that read as painterly: reaction‑diffusion, agent‑based slime‑mould (Physarum) models, flow‑field advection of strokes/particles, and layered stochastic brush‑stroke emulation all move outputs away from “clinical” rule‑based looks toward organic, emergent structure [10],[9],[11].  
- Painterly rendering patterns: advect brush strokes via a semi‑Lagrangian fluid field (use velocity fields or per‑particle velocity textures) and composite multiple stroke‑size layers; reference pipelines place particles/strokes from difference maps and store stroke attributes in reference pictures for screen‑space rendering [11],[13].  
- ML/style approaches: combine data‑driven palette or style transfer at post‑process time when real‑time constraints permit; studios such as Refik Anadol integrate data‑driven systems for “living” surfaces (studio practice, not low‑level recipe in these findings) [16].

## 5. Palette evolution & color practice
- Perceptual interpolation: interpolate in perceptually uniform spaces (CAM02‑UCS / CIECAM02‑based J′a′b′) to avoid hue/saturation artifacts during smooth palette drift; CAM02 provides wider lightness range useful for dynamic palettes [12].  
- Palette grammars & data‑driven palettes: evolve palettes via harmonic interpolation, temperature/hue drift, or ML clustering of salient colors from imagery for context‑aware adaptation (papers and experiments exist for image‑driven palette generation) [16],[12].

## 6. Trails, temporal persistence and painterly smearing
- Trails via Lagrangian particles + ping‑pong advection: store particle positions/velocities in buffers, advect via velocity field each frame, and composite with exponential decay blending to create persistent painterly smears; ping‑pong avoids simultaneous read/write issues [8],[14].  
- Parameters (evidence‑backed): particle life ~4 (example), turbulence intensity ~10 and frequency ~2 produce vivid stylized trails; particle size randomization between 0.05–0.25 yields tactile variation [20],[14]. Use these as starting UI defaults.

## 7. UI/UX controls for non‑technical users
- High‑level metaphors: sliders (faders/knobs) map naturally to continuous parameters (drift speed, turbulence) and are an embodied control metaphor [15]. Example‑based thumbnails, personality sliders (e.g., “calm ←→ frenetic”), and visual affordances (live previews, small gallery of presets) let non‑technical users steer mathematics intuitively; co‑creative patterns and history galleries support exploration [21],[23].  
- Mapping suggestions: map “personality” → composite of drift magnitude, trail decay, palette temperature; expose seed + randomness toggle (seeded reproducibility vs stochastic live).

## 8. Evaluation heuristics & simple user tests
- Forced‑choice similarity tests (texture interpolation style) can measure perceived repetition vs novelty by asking users to pick most/least similar pairs across distances; adopt a simple 2AFC or 3‑interval task to check whether viewers detect repeats [24].  
- Practical heuristics: (1) no identical landmark within N screen‑lengths (use Poisson placement), (2) visible seam energy test (tile checker), (3) qualitative ratings for “alive/painterly” using small panel surveys referencing painterly exemplars [5],[6],[24].

## Evidence gaps
- Direct psychophysical thresholds for when toroidal repetition becomes perceptually detectable on immersive displays are not present in the findings.  
- Specific UI mappings validated by user studies for non‑technical generative controls are lacking.

## Prioritized references (annotations)
1. Domain‑warping and FBM patterns for shader authors — GitHub notes and recommended rotation matrix and hash patterns. https://github.com/MiniMax-AI/skills/blob/main/skills/shader-dev/techniques/domain-warping.md  
2. Stegu’s webgl‑noise demos (Simplex/Perlin/Worley; periodic variants). https://stegu.github.io/webgl-noise/webdemo  
3. Example‑based texture synthesis (Efros/Freeman implementation repo). https://github.com/Devashi-Choudhary/Texture-Synthesis  
4. Unity Technologies – Infinity Tile / Wang tile shader examples for non‑periodic tiling. https://github.com/Unity-Technologies/infinity_tile_shader  
5. Poisson‑disk sampling primer and implementation. https://a5huynh.github.io/posts/2019/poisson-disk-sampling  
6. Blue‑noise / Poisson‑disk survey and theory (JCST). https://jianweiguo.net/publications/papers/2015_JCST_BNMeshSurvey_compress.pdf  
7. Temporal reprojection / TAA blending and the EMA accumulation tradeoffs. https://brashandplucky.com/2023/05/06/reprojection-temporal-antialiasing.html  
8. Ping‑pong buffering pattern for frame history and accumulation. https://hub.jmonkeyengine.org/t/framebuffers-and-the-ping-pong-technique/28459  
9. Physarum / slime‑mould agent‑based generative art projects and models. https://moll.dev/projects/physarum  
10. Reaction‑diffusion systems for emergent organic patterns (artist/technical primer). https://blog.hvidtfeldts.net/index.php/2012/08/reaction-diffusion-systems  
11. Painterly rendering for animation: stroke/particle attribute pipelines and advected strokes. https://icg.gwu.edu/sites/g/files/zaxdzs6126/files/downloads/Painterly%20rendering%20for%20animation.pdf  
12. CAM02‑UCS / perceptual color interpolation guidance. https://files.cie.co.at/x046_2019/x046-PO005.pdf  
13. Multi‑size curved brush stroke painterly repo (example implementation). https://github.com/fionazeng3/Painterly-Rendering-with-Curved-Brush-Strokes-of-Multiple-Sizes  
14. Flow fields and velocity‑texture advection patterns. https://emildziewanowski.com/flowfields  
15. Overview of practical generative art tools (Processing, p5.js, Three.js, TouchDesigner). https://gitnux.org/best/generative-art-software  
16. Generative art primers and tool recommendations; background on analytic/shader workflows. https://generativeart.io/learn.html  
17. Unity compute shader / GPU particle workflows (VFX/compute shader guidance). https://learn.unity.com/tutorial/urp-recipe-compute-shaders  
18. Wang tiles for non‑periodic texture assembly (Cohen et al.). https://cs.jhu.edu/~misha/Spring25/Readings/Cohen03.pdf  
19. Periodic noise demo (periodic variants of Simplex/Perlin). https://stegu.github.io/webgl-noise/webdemo/periodic.html  
20. Unity Stylized Trails tutorial (example parameter values: turbulence≈10, frequency≈2, size 0.05–0.25, life≈4). https://youtube.com/watch?v=wvK6MNlmCCE

## Works Cited
[1] https://github.com/MiniMax-AI/skills/blob/main/skills/shader-dev/techniques/domain-warping.md  
[2] https://stegu.github.io/webgl-noise/webdemo  
[3] https://github.com/Devashi-Choudhary/Texture-Synthesis  
[4] https://github.com/Unity-Technologies/infinity_tile_shader  
[5] https://a5huynh.github.io/posts/2019/poisson-disk-sampling  
[6] https://jianweiguo.net/publications/papers/2015_JCST_BNMeshSurvey_compress.pdf  
[7] https://brashandplucky.com/2023/05/06/reprojection-temporal-antialiasing.html  
[8] https://hub.jmonkeyengine.org/t/framebuffers-and-the-ping-pong-technique/28459  
[9] https://moll.dev/projects/physarum  
[10] https://blog.hvidtfeldts.net/index.php/2012/08/reaction-diffusion-systems  
[11] https://icg.gwu.edu/sites/g/files/zaxdzs6126/files/downloads/Painterly%20rendering%20for%20animation.pdf  
[12] https://files.cie.co.at/x046_2019/x046-PO005.pdf  
[13] https://github.com/fionazeng3/Painterly-Rendering-with-Curved-Brush-Strokes-of-Multiple-Sizes  
[14] https://emildziewanowski.com/flowfields  
[15] https://gitnux.org/best/generative-art-software  
[16] https://generativeart.io/learn.html  
[17] https://learn.unity.com/tutorial/urp-recipe-compute-shaders  
[18] https://cs.jhu.edu/~misha/Spring25/Readings/Cohen03.pdf  
[19] https://stegu.github.io/webgl-noise/webdemo/periodic.html  
[20] https://youtube.com/watch?v=wvK6MNlmCCE
