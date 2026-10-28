#!/usr/bin/env python3
"""Dependency-free checks usable on Linux and macOS; not an iOS build."""
import json, plistlib, re, subprocess, sys, xml.etree.ElementTree as ET
from pathlib import Path
root = Path(__file__).resolve().parents[1]
tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).decode().split("\0")
checked = 0
for rel in filter(None, tracked):
    p = root / rel
    if not p.is_file(): continue
    if p.suffix in {".json", ".xcstrings", ".wowapp"}:
        json.loads(p.read_text())
    elif p.suffix in {".plist", ".entitlements"}:
        plistlib.loads(p.read_bytes())
    elif p.suffix in {".xcscheme", ".xcworkspacedata"}:
        ET.fromstring(p.read_bytes())
    else: continue
    checked += 1
for required in ["Wow.xcworkspace/contents.xcworkspacedata", "CheckBot 首页/ios/CheckBot.xcodeproj/project.pbxproj", "picture-remarker(mainIOS) copy/ios/PictureMarker/EditorView.swift", "提词器 copy/TeleprompterApp/Features/Teleprompter/TeleprompterView.swift"]:
    if not (root / required).is_file(): raise SystemExit("Missing source: " + required)
if (root / "Counter copy/Package.swift").is_file():
    assert (root / "Counter copy/CounterApp/CounterToolEntryView.swift").is_file()
# Product policy: silent video is permitted; audio sessions and microphone inputs are not.
for module in ["CheckBot 首页/ios/CheckBot", "Counter copy/CounterApp", "提词器 copy/TeleprompterApp", "picture-remarker(mainIOS) copy/ios/PictureMarker"]:
    for source in (root / module).rglob("*.swift"):
        code = source.read_text()
        if re.search(r"\b(?:AVAudioPlayer|AVAudioRecorder|AVAudioEngine|AVAudioSession|AVSpeechSynthesizer|SFSpeechRecognizer|AudioServicesPlaySystemSound|AudioServicesPlayAlertSound)\b|\.(?:audio|builtInMicrophone)\b", code):
            raise SystemExit("Audio-owning API is not allowed in native Wow: " + str(source.relative_to(root)))
assert "source.loadTracks(withMediaType: .video)" in (root / "Counter copy/CounterApp/HomeView.swift").read_text()
assert "automaticallyConfiguresApplicationAudioSession = false" in (root / "提词器 copy/TeleprompterApp/Camera/CameraService.swift").read_text()
assert "NSMicrophoneUsageDescription" not in plistlib.loads((root / "CheckBot 首页/ios/CheckBot/Info.plist").read_bytes())
subprocess.run(["git", "-C", str(root), "diff", "--check"], check=True)
test = root / "CheckBot 首页/scripts/test-developer-toolkit.cjs"
if test.is_file(): subprocess.run(["node", "--test", str(test)], check=True, cwd=root)
print(f"Validated {checked} structured source files and required modules. iOS builds/tests require Mac + Xcode.")
