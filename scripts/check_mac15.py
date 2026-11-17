#!/usr/bin/env python3
"""Check prerequisites for the macOS 15 port without an NSP or keys.

This is a bring-up diagnostic, not a game build or a declaration of BOTW support.
It compiles a small Metal 3 program in a temporary directory and checks the
committed native tools. See docs/mac15.md for the remaining renderer work.
"""
import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
MACOS_MIN = '15.6'


class CheckError(Exception):
    pass


def run(cmd, emit, *, env=None):
    cmd = [str(p) for p in cmd]
    emit('$ ' + shlex.join(cmd))
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors='replace', timeout=60, env=env)
    except subprocess.TimeoutExpired as error:
        output = error.stdout
        if output:
            emit(output.decode(errors='replace') if isinstance(output, bytes) else output)
        raise CheckError(f'{cmd[0]} timed out after 60 seconds') from error
    except OSError as error:
        raise CheckError(f'cannot run {cmd[0]}: {error}') from error
    if result.stdout:
        emit(result.stdout.rstrip())
    if result.returncode:
        raise CheckError(f'{cmd[0]} exited with status {result.returncode}')
    return result.stdout.strip()


def check(repo, emit):
    emit('mac15 prerequisite check: Apple silicon, macOS 15.6+, Xcode 26.x')
    emit('This does not build or run BOTW; its Metal 3 renderer is still pending.')
    if platform.system() != 'Darwin':
        raise CheckError('run this check on your Mac; Apple SDKs and a Metal GPU are required')
    if platform.machine() != 'arm64':
        raise CheckError('use an arm64 Python on an Apple silicon Mac, without Rosetta')
    version = run(['sw_vers', '-productVersion'], emit)
    if not re.fullmatch(r'\d+(?:\.\d+){1,2}', version):
        raise CheckError(f'cannot interpret macOS version: {version!r}')
    if tuple(map(int, version.split('.'))) < (15, 6):
        raise CheckError('Xcode 26 requires macOS 15.6 or later')
    if not version.startswith('15.'):
        emit('NOTE: this is a newer macOS; a pass here still needs a macOS 15 run.')
    xcode = run(['xcodebuild', '-version'], emit)
    if not re.search(r'^Xcode 26(?:\.|\s|$)', xcode):
        raise CheckError('select Xcode 26.x with DEVELOPER_DIR or xcode-select, then rerun')
    run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], emit)
    run(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], emit)
    run(['xcrun', '--sdk', 'macosx', 'clang', '--version'], emit)
    emit('If Metal is missing, run: xcodebuild -downloadComponent MetalToolchain')
    run(['xcrun', '--sdk', 'macosx', 'metal', '--version'], emit)

    # These commands print build metadata only; no extraction or game files.
    for relative in ('dm/tools/nx_extract_bin/nx_extract', 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate'):
        if not run([repo / relative, '--source-sha'], emit):
            raise CheckError(f'{relative} returned no source digest')
    run([repo / 'dm/gfx/tools/spirv_cross_bin/spirv-cross', '--revision'], emit)

    source = repo / 'dm/mac/mac15_probe'
    with tempfile.TemporaryDirectory(prefix='nxnative-mac15-') as folder:
        work = Path(folder)
        target = f'-mmacosx-version-min={MACOS_MIN}'
        run(['xcrun', '--sdk', 'macosx', 'metal', '-c', '-std=metal3.2', '-O1',
             target, '-fpreserve-invariance', '-fwrapv', source.with_suffix('.metal'),
             '-o', work / 'probe.air'], emit)
        run(['xcrun', '--sdk', 'macosx', 'metallib', work / 'probe.air',
             '-o', work / 'probe.metallib'], emit)
        run(['xcrun', '--sdk', 'macosx', 'clang', '-arch', 'arm64', target, '-fobjc-arc',
             '-Wall', '-Wextra', '-Werror=unguarded-availability', source.with_suffix('.m'),
             '-framework', 'Foundation', '-framework', 'Metal', '-o', work / 'probe'], emit)
        emit('Running the synthetic GPU check with MTL_DEBUG_LAYER=1')
        run([work / 'probe', work / 'probe.metallib'], emit,
            env={**os.environ, 'MTL_DEBUG_LAYER': '1'})
    emit('PASS: prerequisite probes only. BOTW on macOS 15 still needs the Metal 3 backend.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, help='also write the complete check log to this file')
    args = parser.parse_args(argv)
    try:
        with ExitStack() as stack:
            log = None
            if args.out:
                path = args.out.expanduser()
                path.parent.mkdir(parents=True, exist_ok=True)
                log = stack.enter_context(path.open('w', encoding='utf-8'))

            def emit(message):
                print(message, flush=True)
                if log:
                    log.write(message + '\n')
                    log.flush()

            try:
                check(REPO, emit)
            except (CheckError, OSError) as error:
                emit(f'[RED] mac15 check: {error}')
                return 1
    except OSError as error:
        print(f'[RED] cannot write the check log: {error}', flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
