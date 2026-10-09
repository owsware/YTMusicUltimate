# Song transitions

Open **YTMusicUltimate → Player Settings → Song Transitions**. Enable transitions,
choose AutoMix or Crossfade, and set Crossfade to 1–12 seconds. Two compact toggles sit
beneath Shuffle and Repeat in the native music player. Tap a mode to enable it;
tap the active mode again to turn transitions off. Only one mode is active. Defaults are off, AutoMix, and four seconds.
The controls follow [Apple Music's interaction model](https://support.apple.com/en-ie/105067).
Settings use the existing `YTMUltimate` preferences dictionary and apply live.
Revision 6 caches a normalized, immutable snapshot and refreshes it on preference
changes; frequent native playback queries no longer copy the defaults dictionary.

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
crossfade. Ordinary audio tracks use the user's explicit selection across the
server's known crossfade experiment values (0, 1 and 2). Song
classification uses the verified protobuf music type instead of requiring the
user to select audio-only mode. Sequential album tracks retain native transitions.
Native engine flags are enabled at startup through the actual `YTColdConfig`
facade getters and implementation getters read by playback initialization,
independently of the saved on/off toggle. Both `enableCrossfade` and
`enableVolumeFading` are required: `MLPlayerPoolImpl` uses the first to select
`MLHAMMultiPlayer`, while `YTQueuePlaybackTimelineManager` uses the second to
create the audio transition provider and transition effects. Earlier builds did
not enable the second flag. Transition scheduling stays off until a mode is enabled.
Revision 5 also enables the verified `enablePlayerPlaybackMigration` flag. The
native timeline manager reads the incoming crossfade from `YTSingleVideo.playerPlayback`;
the legacy path stores only the playback configuration and loses that transition.
Both native playback and sequencer-item-handler constructors select media-driven
prefetch, keeping the prepared `YTPlayerPlayback` intact through the upcoming manager.
Online songs otherwise default to a zero-second prefetch window when the endpoint
has no hint. The immediate next song now gets at least 12–20 seconds of prefetch
lead for Crossfade, or 32 seconds for AutoMix's bounded analysis. A longer native
window is preserved. The original window is restored when transitions are disabled,
and native changes to the window are respected. No additional upcoming songs are
requested beyond that immediate next song while transitions are enabled.
An eligible song may reuse the native queue despite the server's preference to
create a new player for the next song, only when YouTube's own gapless check passes
and the response has no preroll/interstitial ads. Forced stream incompatibility
retains native playback. Duration construction checks the actual requesting
sequencer, including during initialization. Planning refreshes copied upcoming
playbacks through the native debounced queue scheduler.
Videos, live streams, podcasts, casting, picture-in-picture and repeat-one bypass
mixing. User-selected playback speeds other than 1× suppress tempo adjustment.

Revision 6 also enables the media-driven prefetch flag read by the music watch
controller before it constructs the main player. The upcoming manager creates
transition controllers without assigning their current content video; it relies
on a media-fetch callback to start their resolvers. The revision 5 device report
contains no such callback, no playable upcoming songs and no incoming audio effect.
The immediate next controller now receives the manager's actual current video via
its verified `setCurrentContentVideo:` method. Its existing time/media/buffer
observers start the native resolver within the preparation window, in foreground
or background. A minimum-buffer configuration cannot trigger our added preparation
more than 32 seconds early. Paused/invalid timing, explicit endpoint vetoes,
unsupported content and external playback prevent that additional prefetch.
Queue replacements and disabling transitions detach the observers and cancel an
obsolete in-flight resolver; YouTube still owns resolution, timeline delivery and
queue advancement. There is no new prefetch polling timer or independent player.
Preparation uses a reusable copy of the native playback config, preserving every
verified field. This avoids changing shared configs already used in native hash
tables. One copy is cached per source config and released with that config.

**Status: all five device builds through revision 5 reported no audible overlap.
Revision 5 confirms the native multi-player and fade provider load, but upcoming
playbacks remain unplayable and the player item has no incoming effect. Revision 6
adds the missing native clock binding and main-player prefetch initialization.
Audible playback, background recovery and artwork synchronization still require
a device test; AutoMix is unverified.**
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
cached analysis only. Tempo recovery runs at 10 Hz with scheduling leeway, solely
on the incoming native audio player's serial queue. It has no UIKit/run-loop
dependency, stops waking while paused, and is removed after recovery/cancellation.
Buffering holds the media clock and never cancels native overlap based on an
elapsed wall-clock timeout. Pitch-algorithm restoration uses the same player queue
and generation guards; stale cleanup cannot reset a newly prepared renderer.
The foreground-only artwork timer runs at 20 Hz during an actual visible blend.

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
wall-clock animation, using a foreground-only 20 Hz artwork timer. Pause
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

## Playback report

After testing a transition, open **YTMusicUltimate → Player Settings → Song
Transitions → Copy Playback Report**. Paste the copied text when reporting a failure.
The report identifies revision 6 and records runtime hook/capability availability,
the actual native player/transition-provider classes, queue compatibility, content
and route/repeat vetoes, scheduled duration, native fade acceptance, simultaneous
player activation, analysis fallback and tempo recovery. It additionally records
prefetch mode/window/result, resolved playbacks, timeline delivery and the actual
native player item's incoming fade. App-state values are
0 = foreground, 1 = inactive and 2 = background.
Revision 6 additionally shows the current prefetch clock, lifecycle/media state,
media time, preparation window and resolver state. Its stages distinguish clock
attachment, actual native resolver start, resolver completion, playable-data
delivery and visible cover blending. The `prefetch-result` stage comes from the
original media-fetch callback path and can remain absent when the new clock binding
starts the same native resolver directly.

This trace is bounded to 48 event counters, 48 last stage results and 32 recent entries in memory. It
has no polling or persistent log writes and includes no account details, song
identifiers or media URLs. It resets when the app exits. Playback buttons remain
the two compact toggles below Shuffle/Repeat; diagnostics add only a settings row.

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
