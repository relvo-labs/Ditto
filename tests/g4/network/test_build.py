#!/usr/bin/env python3
"""Panel-owned build/pack regressions; isolated copies, no desktop services."""
import hashlib
import mmap
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
PANEL = ROOT / 'shell/providers/panel_top'
SDK = ROOT / 'packages/host-sdk/bin/ditto-plugin'


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='panel-build-test-', dir=os.environ['TMPDIR'])
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.panel = self.work / 'panel'
        shutil.copytree(PANEL, self.panel, ignore=shutil.ignore_patterns(
            '*.so', 'BuiltPanelTop.qml', '.gitignore', '*.dittopkg'))
        self.env = dict(os.environ)
        self.env['DITTO_PANEL_NETWORK_BUILD'] = str(self.work / 'build')

    def run_command(self, command, **env):
        result = subprocess.run(command, env={**self.env, **env}, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, end='', flush=True)
        return result

    def build(self, **env):
        result = self.run_command(['bash', str(self.panel / 'build-network.sh')], **env)
        self.assertEqual(result.returncode, 0)
        return self.panel / 'qml/network/libdittonetwork.so'

    def test_missing_qt_fails_before_touching_builtin_output(self):
        out = self.work / 'packages'
        out.mkdir()
        sentinel = out / 'keep.dittopkg'
        sentinel.write_text('previous build')
        result = self.run_command(['bash', str(ROOT / 'scripts/build-builtin-packages.sh'), str(out)],
                                  QT_PREFIX=str(self.work / 'missing-qt'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('qmake', result.stdout)
        self.assertIn('QT_PREFIX', result.stdout)
        self.assertTrue(sentinel.exists(), 'preflight must precede deleting previous archives')

    def test_missing_make_and_compiler_have_actionable_errors(self):
        tools = self.work / 'bin'
        tools.mkdir()
        for name in ['bash', 'dirname']:
            (tools / name).symlink_to(shutil.which(name))
        result = self.run_command(['/bin/bash', str(self.panel / 'build-network.sh'), '--check'], PATH=str(tools))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('make', result.stdout)
        self.assertIn('QT_PREFIX', result.stdout)
        result = self.run_command(['bash', str(self.panel / 'build-network.sh'), '--check'], CXX='missing-panel-cxx')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing-panel-cxx', result.stdout)
        self.assertIn('QT_PREFIX', result.stdout)

    def test_clean_sdk_pack_requires_panel_build(self):
        result = self.run_command(['sh', str(SDK), 'pack', str(self.panel), '--out', str(self.work / 'clean.dittopkg')])
        self.assertNotEqual(result.returncode, 0, 'clean SDK pack must not silently omit native module')
        self.assertIn('package_missing', result.stdout)
        self.assertIn('build first', result.stdout)

    def test_prefix_reproducibility_atomic_copy_and_payload(self):
        qt = Path(self.env['QT_PREFIX'])
        alias = self.work / 'qt-alias'
        alias.symlink_to(qt, target_is_directory=True)
        library = self.build(QT_PREFIX=str(qt))
        before = library.stat().st_ino
        with library.open('rb') as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as mapping:
            original = mapping[:]
            first = self.work / 'first.dittopkg'
            result = self.run_command(['sh', str(SDK), 'pack', str(self.panel), '--out', str(first)])
            self.assertEqual(result.returncode, 0)
            self.build(QT_PREFIX=str(alias))
            self.assertNotEqual(before, library.stat().st_ino, 'replace inode instead of overwriting an mmap')
            self.assertEqual(original, mapping[:])
        second = self.work / 'second.dittopkg'
        result = self.run_command(['sh', str(SDK), 'pack', str(self.panel), '--out', str(second)])
        self.assertEqual(result.returncode, 0)
        dynamic = self.run_command(['readelf', '-d', str(library)])
        self.assertEqual(dynamic.returncode, 0)
        self.assertNotIn('(RUNPATH)', dynamic.stdout)
        self.assertNotIn('(RPATH)', dynamic.stdout)
        hashes = [hashlib.sha256(path.read_bytes()).hexdigest() for path in (first, second)]
        print('same-toolchain archive sha256:', *hashes, flush=True)
        self.assertEqual(*hashes)
        listing = self.run_command(['tar', '--zstd', '-tf', str(second)])
        self.assertEqual(listing.returncode, 0)
        self.assertIn('qml/network/libdittonetwork.so', listing.stdout)
        for entry in listing.stdout.splitlines():
            self.assertFalse(entry.endswith(('.cpp', '.pro', '.sh', '.gitignore')), entry)


if __name__ == '__main__':
    unittest.main(verbosity=2)
