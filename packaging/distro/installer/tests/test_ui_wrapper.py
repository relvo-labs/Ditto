"""Run the real installer UI wrapper with its fixed paths relocated into a
task-owned fixture. Command doubles only record which stage ran."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).resolve().parents[1] / "image/ditto-installer-ui"


class UiWrapperTests(unittest.TestCase):
    def run_wrapper(self, drm=False, gpu=1, software=1, stage=None):
        with tempfile.TemporaryDirectory(prefix="ditto-221-ui-") as temp:
            root = Path(temp)
            commands = root / "bin"
            commands.mkdir()
            calls = root / "calls"
            calls.touch()

            def executable(name, text):
                path = commands / name
                path.write_text("#!/bin/bash\n" + text)
                path.chmod(0o755)
                return path
            executable("dbus-run-session", '''
[[ "$1" == -- && "$3" == --graphical ]] || exit 79
if [[ ${WLR_RENDERER:-} == pixman ]]; then
    [[ $QT_QUICK_BACKEND == software && $WLR_RENDERER_ALLOW_SOFTWARE == 1 ]] || exit 80
    echo software >> "$FIXTURE_CALLS"
    exit "$FIXTURE_SOFTWARE"
fi
echo gpu >> "$FIXTURE_CALLS"
exit "$FIXTURE_GPU"
''')
            text = executable("text-frontend", 'echo text >> "$FIXTURE_CALLS"\n')
            device = root / ("drm/card7-HDMI-A-1/device" if drm == "connector" else "drm/card0/device")
            if drm:
                device.mkdir(parents=True)
            script = WRAPPER.read_text().replace("/sys/class/drm/", str(root / "drm") + "/")
            script = script.replace("/usr/lib/ditto-installer/ditto-installer-text", str(text))
            wrapper = root / "wrapper"
            wrapper.write_text(script.replace("/usr/lib/ditto-installer/ditto-installer-ui", str(wrapper)))
            wrapper.chmod(0o755)
            env = {**os.environ, "PATH": str(commands) + ":" + os.environ["PATH"], "FIXTURE_CALLS": str(calls),
                   "FIXTURE_GPU": str(gpu), "FIXTURE_SOFTWARE": str(software)}
            env.pop("DITTO_INSTALLER_STAGE", None)
            if stage is not None:
                env["DITTO_INSTALLER_STAGE"] = stage
            result = subprocess.run(["bash", str(wrapper)], env=env, text=True, capture_output=True, timeout=10)
            return result.returncode, calls.read_text().splitlines(), result.stdout + result.stderr

    def test_no_drm_goes_straight_to_text(self):
        for drm in (False, "connector"):
            with self.subTest(drm=drm):
                code, calls, output = self.run_wrapper(drm=drm)
                self.assertEqual((code, calls), (0, ["text"]), output)
                self.assertIn("English text screen", output)

    def test_gpu_then_software_then_text(self):
        for gpu, software, expected in ((0, 1, ["gpu"]), (1, 0, ["gpu", "software"]),
                                        (1, 1, ["gpu", "software", "text"])):
            with self.subTest(gpu=gpu, software=software):
                code, calls, output = self.run_wrapper(drm=True, gpu=gpu, software=software)
                self.assertEqual((code, calls), (0, expected), output)

    def test_unknown_stage_is_text_and_arguments_are_fixed(self):
        code, calls, output = self.run_wrapper(drm=True, stage="anything")
        self.assertEqual((code, calls), (0, ["text"]), output)
        result = subprocess.run(["bash", str(WRAPPER), "--other"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
