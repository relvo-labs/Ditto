"""Start only the explicitly addressed, non-activating QA bus and fake keyring."""
import json
import os
from pathlib import Path
import subprocess
import time
from xml.sax.saxutils import escape

from fake_secret_service import private_address


class PrivateBus:
    def __init__(self, scratch, report, log):
        self.scratch, self.report, self.log = Path(scratch), Path(report), log
        self.children = []
        self.address = private_address(scratch, 'unix:path=' + str(Path(scratch).resolve() / 'bus'))
        # Override the parent bus before starting even dbus-daemon.
        self.env = {**os.environ, 'DBUS_SESSION_BUS_ADDRESS': self.address,
                    'DBUS_STARTER_ADDRESS': self.address, 'DBUS_STARTER_BUS_TYPE': 'session'}

    def start(self):
        config = self.scratch / 'bus.conf'
        config.write_text('<busconfig><type>session</type><listen>' + escape(self.address) + '</listen>'
                          '<auth>EXTERNAL</auth><policy context="default"><allow own="*"/>'
                          '<allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>')
        self.children.append(subprocess.Popen(['dbus-daemon', '--nofork', '--config-file=' + str(config)],
                                             env=self.env, stdout=self.log, stderr=self.log))
        self.wait(lambda: (self.scratch / 'bus').exists(), 'private bus')
        self.children.append(subprocess.Popen(['/usr/bin/python3', str(Path(__file__).with_name('fake_secret_service.py')),
                                              '--scratch', str(self.scratch), '--report', str(self.report)],
                                             env=self.env, stdout=self.log, stderr=self.log))
        self.wait(lambda: self.report.exists() and json.loads(self.report.read_text()).get('ready'), 'fake Secret Service')
        return self.address

    def wait(self, ready, phase):
        deadline = time.monotonic() + 10
        while not ready():
            if any(child.poll() is not None for child in self.children):
                raise RuntimeError(phase + ' exited; inspect private-bus.log (sandbox socket may be blocked)')
            if time.monotonic() >= deadline:
                raise RuntimeError(phase + ' readiness timeout')
            time.sleep(.05)

    def stop(self):
        for child in reversed(self.children):
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
