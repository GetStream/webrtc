"""Treat a passed XCTest as a finished run in Chromium's iOS runner.

`ios/build/bots/scripts/test_runner.py` parses xcodebuild output with
`GTestLogParser`. That parser only marks a run complete on
`[  PASSED  ] N tests.` These binaries are XCTest, so a passing run prints
`** TEST EXECUTE SUCCEEDED **` instead. `launch()` then sees `crashed`
with no crashed test, shuts the simulator down, and boots it again.

Loaded automatically when this directory is on `PYTHONPATH`. A run that
never prints a success line is still a crash, and the runner still retries
that case.
"""

import importlib.abc
import importlib.machinery
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

_SUCCEEDED = re.compile(
    r"\*\*\s+TEST\s+EXECUTE\s+SUCCEEDED\s+\*\*"
    r"|Test Suite '(?:All tests|Selected tests)' passed"
)


def _patch(module):
    parser = getattr(module, "GTestLogParser", None)
    process_line = getattr(parser, "_ProcessLine", None)
    if parser is None or process_line is None:
        sys.stderr.write(
            "ios xctest completion hook: GTestLogParser._ProcessLine is "
            "missing; the startup-crash retry stays in place\n"
        )
        return
    if getattr(parser, "_stream_xctest_completion", False):
        return

    def _process_line(self, line):
        process_line(self, line)
        if not self.completed and _SUCCEEDED.search(line):
            self.completed = True
            self._current_test = ""

    parser._ProcessLine = _process_line
    parser._stream_xctest_completion = True


class _GTestCompletionFinder(importlib.abc.MetaPathFinder):
    """Patch gtest_utils after it loads, and leave every other import alone."""

    def find_spec(self, fullname, path, target=None):
        if fullname != "gtest_utils":
            return None
        sys.meta_path.remove(self)
        try:
            spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        finally:
            if self not in sys.meta_path:
                sys.meta_path.insert(0, self)
        if spec is None or spec.loader is None:
            return None
        loader = spec.loader
        original_exec = loader.exec_module

        def exec_module(module):
            original_exec(module)
            _patch(module)

        loader.exec_module = exec_module
        return spec


def install():
    if any(isinstance(finder, _GTestCompletionFinder) for finder in sys.meta_path):
        return
    sys.meta_path.insert(0, _GTestCompletionFinder())


_FIXTURE = textwrap.dedent(
    """\
    class GTestLogParser(object):
        def __init__(self):
            self.completed = False
            self._current_test = ""
            self.crashed = False

        def _ProcessLine(self, line):
            if line.startswith("[  PASSED  ]"):
                self.completed = True
                self._current_test = ""

        def ProcessLine(self, line):
            self._ProcessLine(line)

        def Finalize(self):
            if not self.completed:
                self.crashed = True
    """
)

_CHILD = textwrap.dedent(
    """\
    import gtest_utils

    cases = [
        ("** TEST EXECUTE SUCCEEDED **", False),
        ("Test Suite 'All tests' passed at 2026-11-10 17:38:52.055.", False),
        ("Test Suite 'Selected tests' passed at 2026-11-10 17:38:52.055.", False),
        ("note ** TEST EXECUTE SUCCEEDED **", False),
        ("** TEST EXECUTE FAILED **", True),
        ("Test Suite 'All tests' failed at 2026-11-10 17:38:52.055.", True),
        ("", True),
        ("[  PASSED  ] 192 tests.", False),
    ]
    for line, expect_crashed in cases:
        parser = gtest_utils.GTestLogParser()
        if line:
            parser.ProcessLine(line)
        parser.Finalize()
        if parser.crashed != expect_crashed:
            raise SystemExit(
                "line %r crashed=%s want %s"
                % (line, parser.crashed, expect_crashed)
            )
    print("ok")
    """
)


def selftest():
    hook_dir = os.path.dirname(os.path.abspath(__file__))
    fixture = tempfile.mkdtemp()
    try:
        with open(os.path.join(fixture, "gtest_utils.py"), "w") as handle:
            handle.write(_FIXTURE)
        env = os.environ.copy()
        env["PYTHONPATH"] = os.pathsep.join([hook_dir, fixture])
        probe = subprocess.run(
            [sys.executable, "-c", _CHILD],
            env=env,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    finally:
        shutil.rmtree(fixture)
    if probe.returncode != 0 or probe.stdout.strip() != "ok":
        sys.stderr.write(probe.stdout)
        sys.stderr.write(probe.stderr)
        raise SystemExit("ios xctest completion hook selftest failed")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return 0
    if len(argv) > 1:
        raise SystemExit("usage: sitecustomize.py --selftest")
    install()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

install()
