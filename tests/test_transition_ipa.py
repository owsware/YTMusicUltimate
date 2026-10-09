"""Exercise delivery checks using deliberately small synthetic IPA archives."""
import contextlib
import io
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from verify_transition_ipa import verify


def executable(injected=False, encrypted=False):
    segment = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__TEXT", 0x100000000,
                          4096, 0, 4096, 7, 5, 0, 0)
    commands = [segment]
    if injected:
        name = b"@executable_path/YTMusicUltimate.dylib\0"
        size = (24 + len(name) + 7) & ~7
        commands.append(struct.pack("<IIIIII", 0xC, size, 24, 0, 0, 0) + name +
                        bytes(size - 24 - len(name)))
    if encrypted:
        commands.append(struct.pack("<IIIIII", 0x2C, 24, 0, 10, 1, 0))
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2,
                         len(commands), sum(map(len, commands)), 0, 0)
    return (header + b"".join(commands)).ljust(4096, b"\0")


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.input = Path(self.temp.name) / "input.ipa"
        self.output = Path(self.temp.name) / "output.ipa"
        self.archive(self.input)

    def archive(self, path, injected=False, resources=True, code=True, version="other", encrypted=False):
        root = "Payload/Test.app/"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(root + "Info.plist", plistlib.dumps({
                "CFBundleExecutable": "Test", "CFBundleShortVersionString": version}))
            archive.writestr(root + "Test", executable(injected, encrypted))
            if injected:
                archive.writestr(root + "YTMusicUltimate.dylib", b"YTMUSongTransitionCoordinator\0"
                                 b"SongTransitionsSettingsController\0songTransitionsEnabled\0YTMUPlayerTransitionButton\0"
                                 b"isCrossfadeTransitionEnabledForCurrentPlayerResponse:upcomingPlayerResponse:\0"
                                 b"iosPlayerClientSharedConfigEnableCrossfade\0musicPlaybackClientConfigIosEnableCrossfade\0"
                                 b"prepareArtworkForOutgoingContext:clip:" if code else b"old tweak")
                if resources:
                    archive.writestr(root + "YTMusicUltimate.bundle/en.lproj/Localizable.strings",
                                     b'"SONG_TRANSITIONS" = "Song Transitions";\n"AUTOMIX" = "AutoMix";')

    def check(self, *args):
        with contextlib.redirect_stdout(io.StringIO()):
            return verify(*args)

    def test_unsupported_version_never_reports_device_success(self):
        report = self.check(self.input)
        self.assertFalse(report["supported_transition_build"])
        self.assertEqual(report["on_device_validation"], "not_performed")

    def test_complete_injection(self):
        self.archive(self.output, injected=True)
        self.assertTrue(self.check(self.input, self.output)["injected_transitions_verified"])

    def test_missing_load_command(self):
        self.archive(self.output)
        with self.assertRaisesRegex(ValueError, "does not load"):
            self.check(self.input, self.output)

    def test_missing_resources(self):
        self.archive(self.output, injected=True, resources=False)
        with self.assertRaisesRegex(ValueError, "resources are missing"):
            self.check(self.input, self.output)

    def test_old_tweak_is_rejected(self):
        self.archive(self.output, injected=True, code=False)
        with self.assertRaisesRegex(ValueError, "code missing"):
            self.check(self.input, self.output)

    def test_version_changed_during_injection(self):
        self.archive(self.output, injected=True, version="changed")
        with self.assertRaisesRegex(ValueError, "version differs"):
            self.check(self.input, self.output)

    def test_encrypted_input(self):
        self.archive(self.input, encrypted=True)
        with self.assertRaisesRegex(ValueError, "encrypted"):
            self.check(self.input)


if __name__ == "__main__":
    unittest.main()
