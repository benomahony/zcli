"""Real example conformance, including independent streams and filesystem semantics."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from cli_contract import Harness


def main(binary):
    with tempfile.TemporaryDirectory(prefix='zcli-test-') as directory:
        root = Path(directory)
        sample = root / 'sample.txt'
        data = b'hello\nworld\n'
        sample.write_bytes(data)
        h = Harness(binary, directory)
        help_result = h.run('inspect', '--unknown', '--path', '--help', env={'PARCEL_CONFIG': '/missing'}).check(redirected=True)
        assert b'Examples:' in help_result.out and not help_result.err
        assert b'--dry-run' not in help_result.out and b'--yes' not in help_result.out
        assert b'--dry-run' in h.run('remove', '--help').check().out
        rich_help = h.run('inspect', '--help', stdout_tty=True).check()
        assert '╭'.encode() in rich_help.out and b'Input' in rich_help.out
        assert b'PATH' in rich_help.out and b'[required]' in rich_help.out
        assert b'\x1b' in rich_help.out and not rich_help.err
        assert b'Destructive operations' in h.run('--help', stdout_tty=True).check().out
        mono_help = h.run('inspect', '--help', stdout_tty=True, env={'NO_COLOR': '1'}).check()
        assert b'\x1b' not in mono_help.out and '╭'.encode() in mono_help.out
        plain_help = h.run('inspect', '--help', '--plain', stdout_tty=True).check()
        assert b'\x1b' not in plain_help.out and '╭'.encode() not in plain_help.out
        framed_error = h.run('inspect', stderr_tty=True).check(code=2)
        assert '╭'.encode() in framed_error.err and b'Supply --path' in framed_error.err
        assert not framed_error.out
        assert b'0.1.0' in h.run('--version').check().out
        missing = h.run('inspect').check(code=2, redirected=True)
        assert not missing.out and b'--path' in missing.err
        missing_file = h.run('inspect', '--path=missing.txt').check(code=1, redirected=True)
        assert not missing_file.out and b'--path' in missing_file.err
        result = h.run('inspect', '--path=sample.txt', '--json').check(json_output=True, redirected=True)
        assert b'Inspecting' in result.err
        row = json.loads(result.out)[0]
        assert row == dict(path='sample.txt', bytes=len(data), lines=2, sha256=hashlib.sha256(data).hexdigest())
        plain = h.run('inspect', '-psample.txt', '--plain').check(redirected=True)
        assert plain.out.startswith(b'path="sample.txt"\tbytes=12\tlines=2\tsha256=')
        assert plain.out.count(b'\n') == 1
        assert not h.run('--json', 'inspect', '-p', 'sample.txt', '-q').check(json_output=True).err
        for stdout_tty, stderr_tty in ((True, False), (False, True), (True, True)):
            r = h.run('inspect', '-p', 'sample.txt', stdout_tty=stdout_tty, stderr_tty=stderr_tty).check()
            assert (b'\x1b' in r.out) == stdout_tty, r
            assert (b'\x1b' in r.err) == stderr_tty, r
            if stdout_tty:
                assert '╭'.encode() in r.out
            else:
                assert r.out == plain.out
        for env in ({'NO_COLOR': '1'}, {'TERM': 'dumb'}):
            r = h.run('inspect', '-p', 'sample.txt', stdout_tty=True, stderr_tty=True, env=env).check()
            assert b'\x1b' not in r.out+r.err, r
        r = h.run('inspect', '-p', 'sample.txt', '--no-color', stdout_tty=True, stderr_tty=True).check()
        assert b'\x1b' not in r.out+r.err
        r = h.run('inspect', '-p', 'sample.txt', '--plain', stdout_tty=True, env={'COLUMNS': '10'}).check()
        assert r.out.replace(b'\r\n', b'\n') == plain.out
        r = h.run('inspect', '-p', 'sample.txt', '--json', stdout_tty=True).check(json_output=True)
        assert b'\x1b' not in r.out
        r = h.run('inspect', '-p', 'sample.txt', stdout_tty=True, env={'COLUMNS': '1'}).check()
        assert b'path=' in r.out
        for input_is_tty in (False, True):
            r = h.run('remove', '-p', 'sample.txt', '--no-input', stdin_tty=input_is_tty).check(code=2)
            assert b'--yes' in r.err and not r.out
            assert sample.read_bytes() == data
        r = h.run('remove', '-p', 'sample.txt', '--dry-run', '--json').check(json_output=True)
        assert json.loads(r.out)[0]['action'] == 'would remove'
        assert sample.read_bytes() == data
        config = root / 'parcel.json'
        config.write_text('{"path":"missing.txt"}')
        h.run('inspect', env={'PARCEL_CONFIG': str(config)}).check(code=1)
        h.run('inspect', '--json', env={'PARCEL_CONFIG': str(config), 'PARCEL_PATH': 'sample.txt'}).check(json_output=True)
        h.run('inspect', '-p', 'sample.txt', env={'PARCEL_CONFIG': str(config), 'PARCEL_PATH': 'missing.txt'}).check()
        config.write_text('{"typo":"value"}')
        h.run('inspect', env={'PARCEL_CONFIG': str(config)}).check(code=78)
        config.write_text('not json')
        h.run('inspect', env={'PARCEL_CONFIG': str(config)}).check(code=78)
        h.run('inspect', '--help', env={'PARCEL_CONFIG': str(config)}).check()
        h.run('inspect', '--path=sample.txt', '--', '--help').check(code=2)
        h.run('inspect', '--path=sample.txt', '--dry-run').check(code=2)
        h.run('remove', '-p', 'sample.txt', '--yes', '--json').check(json_output=True)
        assert not sample.exists()
    print('Process conformance passed: help, errors, JSON, streams, PTYs, config, prompts, preview, removal.')


if __name__ == '__main__':
    main(sys.argv[1])
