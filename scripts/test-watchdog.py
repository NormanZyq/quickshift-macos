#!/usr/bin/env python3
"""Exercise process-level recovery without creating or posting any system input."""
import json
import pathlib
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parent.parent
binary = root / ".build" / "watchdog-probe"
binary.parent.mkdir(exist_ok=True)
subprocess.run([
    "xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
    "-I", str(root / "Sources/InputSafety/include"),
    str(root / "Tests/Fixtures/watchdog_probe.c"),
    "-framework", "CoreGraphics", "-framework", "CoreFoundation", "-o", str(binary),
], check=True)
results = []
with tempfile.TemporaryDirectory(prefix="quickshift-watchdog-") as folder:
    for mode, expected_code, expected_fault, maximum_seconds in [
        ("healthy", 0, 0, 2.0), ("callback-stall", 71, 1, 0.4),
        ("worker-stall", 72, 2, 0.6), ("main-stall", 73, 3, 0.9),
        ("idle-main-pause", 0, 0, 2.0), ("main-resumes-with-work", 0, 0, 2.0),
        ("disarmed", 0, 0, 2.0),
    ]:
        status_path = pathlib.Path(folder) / (mode + ".state")
        started = time.monotonic()
        process = subprocess.run([str(binary), mode, str(status_path)], timeout=3, check=False)
        elapsed = time.monotonic() - started
        status = json.loads(subprocess.check_output([str(binary), "status", str(status_path)]))
        assert process.returncode == expected_code, (mode, process.returncode, expected_code)
        assert status["fault"] == expected_fault, (mode, status)
        assert elapsed < maximum_seconds, (mode, elapsed, maximum_seconds)
        results.append({"mode": mode, "exitCode": process.returncode, "seconds": round(elapsed, 4), **status})
report = root / ".build" / "watchdog-tests.json"
report.write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
