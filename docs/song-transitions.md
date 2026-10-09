# Song transitions

Open **YTMusicUltimate → Player Settings → Song Transitions**. Enable transitions,
choose AutoMix or Crossfade, and set Crossfade to 1–12 seconds. Two compact toggles sit
beneath Shuffle and Repeat in the native music player. Tap a mode to enable it;
tap the active mode again to turn transitions off. Only one mode is active. Defaults are off, AutoMix, and four seconds.
The controls follow [Apple Music's interaction model](https://support.apple.com/en-ie/105067).
Settings use the existing `YTMUltimate` preferences dictionary and apply live.

## Compatibility and current verification

The inspected decrypted input is **YouTube Music 9.40.2**, with minimum iOS 17.
Other app versions display an availability explanation and retain native playback.
Every hook is checked against the inspected Objective-C method signature before
installation. Native duration is an integer number of seconds, converted to the
transition constructor's double argument by the original sequencer.

AutoMix additionally requires independent native player rate control and the
actual incoming `AVSampleBufferAudioRenderer` to accept and report Apple's
pitch-preserving spectral algorithm. Missing capabilities retain crossfade or
native playback. An unsupported or inaccessible analysis stream falls back to
crossfade. Ordinary audio tracks accept an unassigned server crossfade experiment
(Unknown = 0); an explicit Disabled = 1 response still vetoes transitions. Song
classification uses the verified protobuf music type instead of requiring the
user to select audio-only mode. Sequential album tracks retain native transitions.
Native engine flags are enabled at startup through the actual `YTColdConfig`
facade getters read by playback initialization, independently of the saved on/off
toggle; transition scheduling stays off until a mode is enabled.
Videos, live streams, podcasts, casting, picture-in-picture and repeat-one bypass
mixing. User-selected playback speeds other than 1× suppress tempo adjustment.

**Status: both earlier device builds reported no audible overlap. The new build
corrects the engine facade flags and current-response getter. Audible playback
and artwork synchronization still require a device test; AutoMix is unverified.**
The reported iOS 26.6.2 device has not been accessed. A successful build does not
prove audible overlap, correct reporting, pitch preservation or battery savings.
AutoMix's musical decisions are an independent implementation; reproducing
Apple's proprietary mixing decisions is outside this feature's scope.

## Playback and resource limits

The native sequencer, upcoming-playback manager, audio fade controllers and
multi-player remain responsible for playback, gains, queue advancement and
metadata. The coordinator schedules no independent player and never advances
the queue itself. Pause/resume retains native control of both players. Seek,
skip, replacement of the current/next song, SponsorBlock seek, preference changes, audio route changes,
interruptions and Low Power Mode changes cancel analysis and restore tempo.
Cancellation clears an active overlap through the native fade and background
player cleanup methods. Routine queue extension and the native handoff do not
cancel the overlap. Reapplying the same playback speed does not discard analysis
or tempo recovery. Native playback owns interruption recovery.

Only the final and opening 12 seconds of the current/next pair are analysed.
Analysis starts from native upcoming playback prefetch and runs on one utility
worker. It uses isolated FFmpeg demux, decoder and resampler contexts, independent
of downloader globals. Native buffered PCM has not been exposed by the verified
interfaces, so the bounded stream decoder is used. Finite unencrypted audio HLS
segments or HTTPS byte ranges are supported; other formats fall back.

Each window has an eight-second processing deadline and a six-MiB download cap.
PCM is mono at 22,050 Hz; only analysis results are cached, with at most 64 entries.
An uncached pair can therefore use up to 12 MiB of additional data. Decode/seek
work may include container headers and segment edges. There is no full-track
download, full-track analysis or continuous idle timer. Low Power Mode uses
cached analysis only. The 20 Hz tempo recovery timer exists only during a mix.

Spectral-flux beat estimates, chroma key estimates and RMS energy guide planning.
Uncertain or incompatible pairs use crossfade. Confident compatible pairs align
beats within the bounded windows, preserve the incoming intro, change incoming
tempo by at most ±6%, then smoothly restore 1× over approximately two seconds
after overlap. The native fade envelope is retained.

## Album artwork during AutoMix

In Song mode, AutoMix dissolves the playing cover into the incoming song's native
cover during the actual overlap, including musical-analysis fallback to crossfade.
The outgoing image is retained in one noninteractive image view over the native
thumbnail. YouTube keeps ownership of incoming image loading and caching; the
feature makes no extra artwork requests and adds no settings or controls.

Progress follows the outgoing native player's media clock, rather than a
wall-clock animation, and shares the existing 20 Hz transition timer. Pause
holds the current blend; buffering cannot advance it. If the incoming cover
loads late, the old cover stays visible until it can dissolve over the remaining
overlap. No timer runs for an idle cover. Missing or hidden artwork skips the
effect. Mode changes, seeks/skips, queue replacement, route changes,
interruptions, backgrounding and cancellation release the temporary image.
Native thumbnail layout, clipping and cover content mode remain in use.

## GitHub Action delivery

Run **Build and Release YTMusicUltimate** with the existing `ipa_url` input set to
a direct downloadable URL for your decrypted IPA. A Windows file path cannot be
used by the hosted runner. The workflow compiles the feature inside the existing
tweak with `SIDELOADING=1` and injects the package using the existing cyan step.

The existing GitHub workflow is unchanged. Its draft release contains the IPA.
The standalone verification script below records the actual input version and
executable hash, verifies the 9.40.2 playback interfaces, and checks the injected
code and settings resources. Run it against the downloaded build. Its report
explicitly records `on_device_validation: not_performed`.

The player toggles use transparent backgrounds and native control colours,
including artwork-derived themes and the tweak's OLED theme. A small dot marks
the active mode, and each toggle has a 44-point touch target and an accessible
on/off value. Native music layouts reserve a row so the toggles remain inside
the player instead of floating over queue items. Settings use the existing
tweak's red accent and standard compact controls.

Local analysis tests can be run with:

```sh
cc -std=c11 -Wall -Wextra -Werror -O2 tests/test_mix.c Source/Transitions/YTMUMixAnalysis.c -lm -o test-mix
./test-mix
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/verify_transition_ipa.py input.ipa --output output.ipa --report validation.json
```

## Device acceptance checks still required

- Compare off, Crossfade (1, 4, 12 seconds), and AutoMix on the same queue; verify
  audible overlap and seamless sequential album playback.
- Use compatible beats, mismatched tempos, quiet intros, ambiguous rhythms and
  short songs. Check ±6% tempo adaptation and smooth recovery without pitch drift.
- With AutoMix selected in Song mode, verify that both covers blend during the
  audio overlap (including analysis fallback), pause/buffering hold the blend,
  and switching to Video mode or backgrounding leaves no stale cover. Test slow
  artwork loading and consecutive tracks sharing the same cover.
- Verify one queue advancement per song, correct progress and artwork/title in
  the app and lock screen, pause/resume during overlap, and background playback.
- During overlap, seek, skip, edit/reorder the queue, trigger SponsorBlock,
  change Bluetooth routes, receive an interruption, and enable Low Power Mode.
  Check normal gains/speed, cancellation and continued native playback.
- Check video, podcast, live, repeat-one and casting bypasses, inaccessible
  streams, and unavailable capabilities without crashes or duplicate playback.
- Compare identical queues with transitions disabled/enabled using Instruments
  CPU, Allocations, Energy Log and Network profiling. Record device, app/iOS
  versions, stream quality, cached/uncached state and measurements. Confirm cache
  bounds and no idle analysis or timer activity before declaring AutoMix complete.
