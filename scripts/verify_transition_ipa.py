#!/usr/bin/env python3
"""Validate the input ABI and the transition tweak in an injected IPA. No extraction."""
import argparse
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath


class MachO:
    def __init__(self, data):
        if data[:4] == bytes.fromhex("cafebabe"):
            for i in range(struct.unpack_from(">I", data, 4)[0]):
                cpu, _, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + 20 * i)
                if cpu == 0x100000C:
                    data = data[offset:offset + size]
                    break
        if data[:4] != bytes.fromhex("cffaedfe") or struct.unpack_from("<I", data, 4)[0] != 0x100000C:
            raise ValueError("Expected an arm64 Mach-O executable")
        self.data = data
        self.segments, self.sections, self.dylibs = [], {}, []
        self.chained = False
        self.encrypted = False
        position = 32
        for _ in range(self.u32(16)):
            command, size = struct.unpack_from("<II", data, position)
            if size < 8 or position + size > len(data):
                raise ValueError("Invalid Mach-O load command")
            if command == 0x19:
                vm, vm_size, file_offset, file_size = struct.unpack_from("<QQQQ", data, position + 24)
                self.segments.append((vm, file_offset, file_size))
                for i in range(self.u32(position + 64)):
                    at = position + 72 + i * 80
                    name = data[at:at + 16].split(b"\0")[0].decode("ascii")
                    self.sections[name] = (self.u64(at + 40), self.u32(at + 48))
            elif command == 0x80000034:
                self.chained = True
                offset = self.u32(position + 8)
                starts = offset + self.u32(offset + 4)
                for i in range(self.u32(starts)):
                    segment_offset = self.u32(starts + 4 + i * 4)
                    if segment_offset:
                        pointer_format = struct.unpack_from("<H", data, starts + segment_offset + 6)[0]
                        if pointer_format != 6:
                            raise ValueError(f"Unsupported chained pointer format {pointer_format}")
            elif command in (0xC, 0x80000018):
                offset = position + self.u32(position + 8)
                self.dylibs.append(data[offset:data.index(b"\0", offset)].decode("utf-8"))
            elif command == 0x2C:
                self.encrypted = bool(self.u32(position + 16))
            position += size
        self.base = min(vm for vm, _, size in self.segments if size)

    def u32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def u64(self, offset):
        return struct.unpack_from("<Q", self.data, offset)[0]

    def pointer(self, offset):
        value = self.u64(offset)
        if not value:
            return 0
        if not self.chained:
            return value
        if value >> 63:
            raise ValueError("External bind where an internal pointer was expected")
        return self.base + (value & 0xFFFFFFFFF)

    def mapped(self, address):
        for vm, offset, size in self.segments:
            if vm <= address < vm + size:
                return offset + address - vm
        raise ValueError(f"Unmapped address {address:x}")

    def string(self, address):
        offset = self.mapped(address)
        return self.data[offset:self.data.index(b"\0", offset)].decode("utf-8")

    def methods(self, address):
        if not address:
            return {}
        offset = self.mapped(address)
        flags, count = struct.unpack_from("<II", self.data, offset)
        stride = flags & 0xFFFF
        if not stride or count > 10000:
            raise ValueError("Invalid Objective-C method list")
        result = {}
        for i in range(count):
            at = offset + 8 + i * stride
            if flags & 0x80000000:
                name = address + 8 + i * stride + struct.unpack_from("<i", self.data, at)[0]
                types = address + 12 + i * stride + struct.unpack_from("<i", self.data, at + 4)[0]
                if not flags & 0x40000000:
                    name = self.pointer(self.mapped(name))
            else:
                name, types = self.pointer(at), self.pointer(at + 8)
            result[self.string(name)] = self.string(types)
        return result

    def classes(self):
        size, offset = self.sections.get("__objc_classlist", (0, 0))
        result = {}
        for at in range(offset, offset + size, 8):
            cls = self.mapped(self.pointer(at))
            ro = self.mapped(self.pointer(cls + 32) & ~7)
            methods = self.methods(self.pointer(ro + 32))
            meta = self.mapped(self.pointer(cls))
            meta_ro = self.mapped(self.pointer(meta + 32) & ~7)
            methods.update({"+" + name: types for name, types in self.methods(self.pointer(meta_ro + 32)).items()})
            result[self.string(self.pointer(ro + 24))] = methods
        return result


EXPECTED_METHODS = {
    "YTMSettingsImpl": {"isCrossfadeEnabled": "B16@0:8", "crossfadeDuration": "q16@0:8"},
    "YTMPlayerSequencerController": {
        "initWithPlayerViewController:": "@24@0:8@16",
        "crossfadeTransitionFromSettings": "@16@0:8",
        "updateCrossfadeTransitionInActiveSequence": "v16@0:8",
        "scheduleSetSequenceForQueueModification": "v16@0:8",
        "updateUpcomingVideoIDAndLatencyTickLoggerForSequence:currentSequenceIndex:isLoopAllEnabled:": "v36@0:8@16q24B32",
        "resetSequence": "v16@0:8",
        "setSequenceForTapNextOrTapPrevWithPlayerTransition:playbackConfig:": "v32@0:8@16@24",
    },
    "YTCrossfadeTransition": {"initWithDuration:": "@24@0:8d16"},
    "MLHAMMultiPlayer": {
        "spawnCrossfadeWithActiveContext:activeClip:nextContext:": "v40@0:8@16@24@32",
        "pauseWithStoppageReason:": "v20@0:8i16", "play": "v16@0:8", "setRate:": "v20@0:8f16",
        "clearBackgroundPlayer": "v16@0:8",
        "rate": "f16@0:8",
    },
    "MLHAMQueuePlayer": {"setRate:": "v20@0:8f16", "rate": "f16@0:8", "currentTime": "{?=ddd}16@0:8", "playerQueue": "@16@0:8"},
    "YTUpcomingPlaybackManager": {"upcomingPlayerTransitionController:didFetchUpcomingPlayablePlaybackData:": "v32@0:8@16@24"},
    "HAMSBARAudioTrackRenderer": {"underlyingRenderer": "@16@0:8", "createRendererAndReturnError:": "B24@0:8^@16"},
    "MLHAMQueuePlayerContext": {"audioFadeController": "@16@0:8"},
    "MLAudioFadeController": {"setPendingTransitionEffects:": "v24@0:8@16"},
    "YTPlayerViewController": {
        "shouldPlaybackController:applyTransitionEffect:currentPlayerResponse:upcomingPlayerResponse:": "B48@0:8@16@24@32@40",
        "seekToTime:": "v24@0:8d16", "seekToTime:seekSource:": "v28@0:8d16i24",
        "seekToTime:toleranceBefore:toleranceAfter:seekSource:": "v44@0:8d16d24d32i40",
    },
    "YTColdConfigMusicPlaybackClientConfigImpl": {"iosEnableCrossfade": "B16@0:8"},
    "YTColdConfigIosPlayerClientSharedConfigImpl": {"enableCrossfade": "B16@0:8"},
    "YTMCrossfadeTransitionPolicy": {
        "+isCrossfadeTransitionEnabledForCurrentPlayerResponse:upcomingPlayerResponse:": "B32@0:8@16@24",
    },
    "YTMPlayerControlsView": {
        "layoutSubviews": "v16@0:8", "sizeThatFits:": "{CGSize=dd}32@0:8{CGSize=dd}16",
        "style": "q16@0:8", "shuffleButton": "@16@0:8", "loopButton": "@16@0:8",
    },
    "YTMNowPlayingView": {
        "sizeThatFits:": "{CGSize=dd}32@0:8{CGSize=dd}16", "playerControlsView": "@16@0:8",
        "playerControlsViewHeight": "d16@0:8", "layoutMod3ActionBarScrubberAbovePlayerControls": "v16@0:8",
    },
}


def read_app(archive):
    infos = [name for name in archive.namelist()
             if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")]
    if len(infos) != 1:
        raise ValueError("Expected one main application in the IPA")
    info = plistlib.loads(archive.read(infos[0]))
    root = infos[0].rsplit("/", 1)[0]
    executable = info["CFBundleExecutable"]
    if PurePosixPath(executable).name != executable:
        raise ValueError("Invalid app executable name")
    return root, info, archive.read(root + "/" + executable)


def verify(input_path, output_path=None):
    with zipfile.ZipFile(input_path) as archive:
        _, info, data = read_app(archive)
    version = info.get("CFBundleShortVersionString")
    binary = MachO(data)
    if binary.encrypted:
        raise ValueError("The input IPA executable is encrypted; supply a decrypted IPA")
    report = {"input_app_version": version, "minimum_ios": info.get("MinimumOSVersion"),
              "executable_sha256": hashlib.sha256(data).hexdigest(),
              "supported_transition_build": version == "9.40.2", "on_device_validation": "not_performed"}
    if version == "9.40.2":
        classes = binary.classes()
        mismatches = []
        for cls, methods in EXPECTED_METHODS.items():
            for method, types in methods.items():
                if classes.get(cls, {}).get(method) != types:
                    mismatches.append(f"{cls}.{method}")
        if mismatches:
            raise ValueError("Playback ABI mismatch: " + ", ".join(mismatches))
        report["verified_private_methods"] = sum(len(methods) for methods in EXPECTED_METHODS.values())
    else:
        print("::warning::This app version is outside the verified 9.40.2 profile; song transitions stay unavailable.")
    if output_path:
        with zipfile.ZipFile(output_path) as archive:
            root, output_info, output_binary = read_app(archive)
            if output_info.get("CFBundleShortVersionString") != version:
                raise ValueError("The output app version differs from the input IPA")
            loads = MachO(output_binary).dylibs
            injected = [path for path in loads if "YTMusicUltimate" in PurePosixPath(path).name]
            if not injected:
                raise ValueError("The app executable does not load YTMusicUltimate")
            libraries = [name for name in archive.namelist() if name.startswith(root + "/")
                         and PurePosixPath(name).name == PurePosixPath(injected[0]).name]
            if len(libraries) != 1:
                raise ValueError("Could not locate the injected transition library")
            tweak = archive.read(libraries[0])
            for marker in (b"YTMUSongTransitionCoordinator", b"SongTransitionsSettingsController", b"songTransitionsEnabled",
                           b"YTMUPlayerTransitionButton", b"isCrossfadeTransitionEnabledForCurrentPlayerResponse:upcomingPlayerResponse:"):
                if marker not in tweak:
                    raise ValueError(f"Transition code missing from injected library: {marker.decode()}")
            resources = [name for name in archive.namelist()
                         if name.startswith(root + "/") and name.endswith("/YTMusicUltimate.bundle/en.lproj/Localizable.strings")]
            if len(resources) != 1:
                raise ValueError("Transition settings resources are missing")
            strings = archive.read(resources[0])
            try:
                localized = plistlib.loads(strings)
                valid = "SONG_TRANSITIONS" in localized and "AUTOMIX" in localized
            except plistlib.InvalidFileException:
                valid = b"SONG_TRANSITIONS" in strings and b"AUTOMIX" in strings
            if not valid:
                raise ValueError("Transition labels are missing from the settings bundle")
            report["injected_transitions_verified"] = True
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = verify(args.input, args.output)
        if args.report:
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
    except (ValueError, KeyError, struct.error, zipfile.BadZipFile, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
