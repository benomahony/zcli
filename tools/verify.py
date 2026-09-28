#!/usr/bin/env python3
"""Verify the exact requested compilers and the installed-example freshness contract."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--zig16', required=True, type=Path)
parser.add_argument('--zig-dev', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
for compiler, expected in ((args.zig16, '0.16.'), (args.zig_dev, '0.17.')):
    if not compiler.is_absolute():
        parser.error('Compiler paths must be absolute; PATH lookup is deliberately disabled.')
    version = subprocess.check_output([str(compiler), 'version'], text=True).strip()
    assert version.startswith(expected), (compiler, version, expected)
    print(f'Compiler: {compiler}\nVersion: {version}', flush=True)
    subprocess.run([str(compiler), 'fmt', '--check', 'build.zig', 'src', 'examples'], cwd=root, check=True)
    subprocess.run([str(compiler), 'build', 'test', 'conformance', '--summary', 'all'], cwd=root, check=True)
    subprocess.run([str(compiler), 'build'], cwd=root, check=True)
    installed = root / 'zig-out/bin/parcel'
    # Simulate a stale installation. Running the example MUST replace this file.
    installed.unlink()
    installed.write_bytes(b'stale-example-binary\n')
    subprocess.run([str(compiler), 'build', 'run', '--', '--version'], cwd=root, check=True)
    assert subprocess.check_output([str(installed), '--version'], text=True).strip() == 'parcel 0.1.0'
    print('Installed example was refreshed by build run.\n', flush=True)
print('Both compiler suites and installation freshness checks passed.')
