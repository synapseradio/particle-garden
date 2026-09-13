---
group: audio
---

# Audio

The microphone becomes six more sources the world can be played through,
switched on and off with one control, sending nothing anywhere but into the
six meters and the mappings that listen to them.

- **Listen** — starts and stops the microphone. Turning it on asks the
  browser for permission in the same click; turning it off releases the
  microphone completely, and the operating system's own recording light
  goes dark with it. What is captured never leaves this path: it is not
  played back, not saved, not sent anywhere — only measured, frame by
  frame, and then forgotten.

The line under the switch names what is happening. While the prompt is
open it reads Requesting; once you answer, it settles to Connected or, if
you decline, to Denied — and declining moves nothing else in the world. To
try again after a refusal, open the browser's site settings (usually
behind the padlock or the site name in the address bar), allow the
microphone there, and press Listen once more. If the room goes quiet for a
while during a connected listen, the line reads Silent rather than sitting
still and unexplained — sound returns it to Connected on its own.

Six meters show what the room is doing right now, each finding the room's
own quiet and its own loud on its own, whatever the microphone's gain
happens to be:

- **audio:loudness** — the room's energy, overall.
- **audio:bass** — its weight, down low.
- **audio:mid** — its body, in the middle.
- **audio:high** — its sparkle, up top.
- **audio:brightness** — its colour, how far the sound leans toward the
  sparkle rather than sitting in the weight.
- **audio:onset** — its hits, a flash on a beat or an attack that fades
  rather than a level that holds.

Three sources already move the world. **audio:bass** feeds `fluidStrength`:
the room's weight presses on the fluid the way real bass presses on the
air. **audio:loudness** feeds `forceStrength`: the room's energy animates
the same push that drives the species dance. And every hit from
**audio:onset** kicks that same push for a moment, riding `forceStrength`
alongside loudness, so the whole world feels the hit and the kick falls
away between hits. A slider a source is moving shows the excursion as a
shaded span beside its handle; the handle itself stays where you left it,
and a saved preset keeps your number rather than the room's.

One more row is wired in but sits at zero, present without yet acting:
**audio:high** into `glowIntensity`. To raise it once the first two feel
familiar, export the mapping from the MIDI section, set that mapping's
depth, and import it back; point a source at a different target the same
way. An audio mapping is an ordinary mapping, listed with the rest and
free to be retargeted or removed like any other.
