"""Reusable process/PTY harness; Python standard library only, no test packages."""
import errno
import json
import os
import selectors
import subprocess
import time
from dataclasses import dataclass


@dataclass
class Result:
    code: int
    out: bytes
    err: bytes

    def check(self, code=0, json_output=False, redirected=False):
        assert self.code == code, self
        if json_output:
            assert isinstance(json.loads(self.out), list), self
        if redirected:
            assert not any(c in self.out + self.err for c in (b'\x1b', b'\r')), self
        assert b'stack trace' not in self.err.lower(), self
        return self


class Harness:
    def __init__(self, binary, cwd=None):
        self.binary = os.path.abspath(binary)
        self.cwd = cwd

    def run(self, *args, env=None, stdout_tty=False, stderr_tty=False,
            stdin_tty=False, timeout=5):
        environment = dict(os.environ)
        for key in ('NO_COLOR', 'FORCE_COLOR', 'PARCEL_CONFIG', 'PARCEL_PATH'):
            environment.pop(key, None)
        environment.update(TERM='xterm-256color', COLUMNS='100')
        environment.update(env or {})
        pairs = []
        def terminal():
            master, slave = os.openpty()
            pairs.append((master, slave))
            return master, slave
        out_pair = terminal() if stdout_tty else None
        err_pair = terminal() if stderr_tty else None
        in_pair = terminal() if stdin_tty else None
        proc = subprocess.Popen([self.binary, *args], cwd=self.cwd, env=environment,
                                stdin=in_pair[1] if in_pair else subprocess.DEVNULL,
                                stdout=out_pair[1] if out_pair else subprocess.PIPE,
                                stderr=err_pair[1] if err_pair else subprocess.PIPE)
        # Keep the input PTY open, but never feed it. A mistaken prompt must time out.
        for _, slave in pairs:
            os.close(slave)
        streams = [out_pair[0] if out_pair else proc.stdout.fileno(),
                   err_pair[0] if err_pair else proc.stderr.fileno()]
        chunks = [bytearray(), bytearray()]
        deadline = time.monotonic() + timeout
        try:
            with selectors.DefaultSelector() as selector:
                for index, fd in enumerate(streams):
                    selector.register(fd, selectors.EVENT_READ, index)
                while selector.get_map():
                    if time.monotonic() > deadline:
                        raise AssertionError(f'CLI hung (possibly prompted): {args!r}')
                    for key, _ in selector.select(0.1):
                        try:
                            data = os.read(key.fd, 65536)
                        except OSError as exc:
                            if exc.errno != errno.EIO:
                                raise
                            data = b''
                        if data:
                            chunks[key.data].extend(data)
                        else:
                            selector.unregister(key.fd)
                code = proc.wait(timeout=max(0.1, deadline-time.monotonic()))
            return Result(code, bytes(chunks[0]), bytes(chunks[1]))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            for master, _ in pairs:
                os.close(master)
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()
