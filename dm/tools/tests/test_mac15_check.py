"""The mac15 checks fail promptly and keep useful diagnostics.

Commands are mocked here; the actual Metal checks must run on an Apple silicon
Mac with Xcode 26. No game files, Apple SDKs or GPU are needed for these tests.
"""
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('check_mac15', REPO / 'scripts/check_mac15.py')
assert spec and spec.loader
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class Mac15Check(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.messages = []
        self.system = mock.patch.object(check.platform, 'system', return_value='Darwin')
        self.machine = mock.patch.object(check.platform, 'machine', return_value='arm64')
        self.system.start(); self.machine.start()
        self.addCleanup(self.system.stop); self.addCleanup(self.machine.stop)

    def run_commands(self, *, fail=None, version='15.6.1', xcode='26.3'):
        def run(cmd, **kwargs):
            self.calls.append((cmd, kwargs))
            if fail and fail in cmd:
                return subprocess.CompletedProcess(cmd, 1, 'specific compiler or GPU failure\n')
            output = 'ok\n'
            if cmd[0] == 'sw_vers': output = version + '\n'
            elif cmd[0] == 'xcodebuild': output = f'Xcode {xcode}\nBuild version test\n'
            elif cmd[-1] == '--source-sha': output = '0123456789abcdef\n'
            return subprocess.CompletedProcess(cmd, 0, output)
        return mock.patch.object(check.subprocess, 'run', side_effect=run)

    def test_success_is_only_a_core_result_and_uses_no_ios_sdk(self):
        with self.run_commands():
            check.check(Path('/checkout with spaces'), self.messages.append)
        commands = [cmd for cmd, _ in self.calls]
        self.assertIn('prerequisites and Metal 3 backend core only', self.messages[-1])
        self.assertIn('NVN replay and BOTW integration are still pending', self.messages[-1])
        self.assertFalse(any('iphoneos' in cmd or '-downloadComponent' in cmd for cmd in commands))
        self.assertTrue(any('/checkout with spaces/dm/mac/mac15_probe.m' in cmd for cmd in commands))
        self.assertTrue(any('/checkout with spaces/dm/gfx/nvn/nvn_mtl3.m' in cmd for cmd in commands))
        self.assertTrue(any('/checkout with spaces/dm/gfx/tests/t_mtl3_range.c' in cmd for cmd in commands))
        self.assertEqual(self.calls[-1][1]['env']['MTL_DEBUG_LAYER'], '1')
        self.assertFalse(Path(commands[-1][0]).exists())   # temporary build is removed

    def test_wrong_host_stops_without_launching_any_tools(self):
        for system, machine in [('Linux', 'aarch64'), ('Darwin', 'x86_64')]:
            with self.subTest(system=system, machine=machine), \
                    mock.patch.object(check.platform, 'system', return_value=system), \
                    mock.patch.object(check.platform, 'machine', return_value=machine), self.run_commands():
                with self.assertRaises(check.CheckError):
                    check.check(REPO, self.messages.append)
        self.assertEqual(self.calls, [])

    def test_old_os_or_wrong_xcode_stops_before_native_tools(self):
        for settings in ({'version': '15.5'}, {'version': 'unknown'}, {'xcode': '16.4'}):
            with self.subTest(settings=settings), self.run_commands(**settings):
                with self.assertRaises(check.CheckError):
                    check.check(REPO, self.messages.append)
        self.assertFalse(any('--source-sha' in cmd for cmd, _ in self.calls))

    def test_shader_compile_failure_prevents_link_and_run(self):
        with self.run_commands(fail='-c'), self.assertRaises(check.CheckError):
            check.check(REPO, self.messages.append)
        self.assertIn('specific compiler or GPU failure', '\n'.join(self.messages))
        self.assertFalse(any('metallib' in cmd for cmd, _ in self.calls))

    def test_native_tool_failure_prevents_shader_build(self):
        with self.run_commands(fail='--source-sha'), self.assertRaises(check.CheckError):
            check.check(REPO, self.messages.append)
        self.assertFalse(any('-c' in cmd for cmd, _ in self.calls))

    def test_missing_tool_and_timeout_report_the_cause(self):
        for error in (FileNotFoundError('missing tool'), subprocess.TimeoutExpired(['probe'], 60, output=b'last GPU line\n')):
            with self.subTest(error=error), mock.patch.object(check.subprocess, 'run', side_effect=error):
                with self.assertRaises(check.CheckError):
                    check.run(['probe'], self.messages.append)
        self.assertIn('last GPU line', '\n'.join(self.messages))

    def test_gpu_failure_is_not_a_pass(self):
        for binary in ('probe', 'range', 'backend'):
            def failed_probe(cmd, emit, *, failed_binary=binary, **kwargs):
                if Path(cmd[0]).name == failed_binary: raise check.CheckError('GPU/CPU readback differs')
                return {'sw_vers': '15.6', 'xcodebuild': 'Xcode 26.0'}.get(cmd[0], 'ok')
            with self.subTest(binary=binary), mock.patch.object(check, 'run', side_effect=failed_probe), \
                    self.assertRaisesRegex(check.CheckError, 'readback'):
                check.check(REPO, self.messages.append)
            self.assertFalse(any(m.startswith('PASS:') for m in self.messages))

    def test_backend_compile_failure_is_not_a_pass(self):
        with self.run_commands(fail=str(REPO / 'dm/gfx/nvn/nvn_mtl3.m')), self.assertRaises(check.CheckError):
            check.check(REPO, self.messages.append)
        self.assertTrue(any(Path(cmd[0]).name == 'probe' for cmd, _ in self.calls))
        self.assertFalse(any(Path(cmd[0]).name == 'backend' for cmd, _ in self.calls))
        self.assertFalse(any(m.startswith('PASS:') for m in self.messages))

    def test_failure_is_written_to_the_requested_log(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'logs with spaces/mac15.log'
            with self.run_commands(fail='metal'), redirect_stdout(io.StringIO()):
                result = check.main(['--out', str(log)])
            self.assertEqual(result, 1)
            self.assertIn('specific compiler or GPU failure', log.read_text())
            self.assertIn('[RED] mac15 check:', log.read_text())


if __name__ == '__main__':
    unittest.main()
