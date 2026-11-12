import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]

START_PASTE = b"\x1b[200~"
END_PASTE = b"\x1b[201~"

# Stands in for an agent. Like Pi and Claude Code, it turns on bracketed paste
# and reports its status through the Program Status Protocol (OSC 7501), such
# as `state=idle:app=pi`. Then it appends every byte it reads to a log. Raw
# mode keeps the terminal driver from editing the input, so the log holds the
# bytes exactly as Rex wrote them.
AGENT = r"""
import os, sys, tty
log, status = sys.argv[1:]
tty.setraw(0)
os.write(1, b"\x1b[?2004h\x1b]7501;" + status.encode() + b"\x1b\\")
with open(log, "ab", buffering=0) as f:
    while True:
        data = os.read(0, 65536)
        if not data:
            break
        f.write(data)
"""

# For a caller's terminal, which only has to stay open.
IDLE = ["sleep", "600"]

SEND = "require('wincent.shannon.private').send({ file = 'example.txt', line_start = 3, line_end = 3 }, arg[1])"


def wait_for(condition, what, timeout=10):
    deadline = time.monotonic() + timeout
    while True:
        result = condition()
        if result:
            return result
        if time.monotonic() > deadline:
            raise AssertionError("timed out waiting for " + what)
        time.sleep(0.05)


@unittest.skipUnless(shutil.which("rex") and shutil.which("nvim"), "requires rex and nvim")
class RexTests(unittest.TestCase):
    """Smoke tests for the Rex backend, against a real Rex server."""

    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp(prefix="shannon-"))
        cls.addClassCleanup(shutil.rmtree, cls.dir)
        # REX_RUNTIME_DIR moves the socket that every rex command connects to,
        # including the commands that run in the server's own terminals. So
        # the tests start their own Rex server, also when you run them inside
        # Rex, where the test sessions would otherwise open in your Rex app.
        # Without XDG_RUNTIME_DIR, Neovim puts its socket under TMPDIR, as on
        # macOS, so its socket stays in this directory too.
        cls.env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("REX_", "TMUX")) and key != "XDG_RUNTIME_DIR"}
        cls.env.update(REX_RUNTIME_DIR=str(cls.dir), TMPDIR=str(cls.dir))
        config = cls.dir / "init.lua"
        config.touch()
        (cls.dir / "send.lua").write_text(SEND)
        server = subprocess.Popen(
            ["rex", "server", "run", "--restore=false", "--config", str(config),
             "--state-dir", str(cls.dir / "state")],
            env=cls.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        cls.addClassCleanup(server.wait, timeout=10)
        cls.addClassCleanup(server.terminate)
        wait_for(lambda: cls.run_rex("whoami").returncode == 0, "the Rex server")

    @classmethod
    def run_rex(cls, *args):
        return subprocess.run(["rex", "--autostart=false", *args], env=cls.env,
                              capture_output=True, text=True, timeout=10)

    def rex(self, *args):
        result = self.run_rex(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def terminal(self, command, beside=None):
        """Starts `command` in a new terminal and returns its block id.

        The first terminal gets a session of its own. Pass `beside` to put
        the terminal in the same window as that one, after it.
        """
        flags = ["--shell=none", "--json", "--", *command]
        if beside is not None:
            return json.loads(self.rex("split", "-b", beside, *flags))["block_ids"][0]
        session = json.loads(self.rex("new", *flags))
        self.addCleanup(self.rex, "kill", session["session_id"])
        return session["initial_windows"][0]["block_ids"][0]

    def agent(self, status, beside=None):
        """Starts the stand-in agent and returns its block id and input log."""
        fd, log = tempfile.mkstemp(suffix=".log", dir=self.dir)
        os.close(fd)
        log = Path(log)
        block_id = self.terminal([sys.executable, "-c", AGENT, str(log), status], beside)
        wait_for(lambda: json.loads(self.rex("block", "call", "-b", block_id,
                                             "program_status"))["records"],
                 "the status of " + block_id)
        return block_id, log

    def caller_env(self, block_id):
        """The environment of a program in the terminal `block_id`, which
        Rex names in REX_BLOCK."""
        return dict(self.env, REX_BLOCK=block_id)

    def shannon(self, caller, text):
        """Sends `text` through Shannon from a Neovim that acts as if it runs
        in the terminal `caller`. Returns Neovim's result and the prompt that
        Shannon builds."""
        server = str(self.dir / "caller.sock")
        result = subprocess.run(
            ["nvim", "--clean", "--listen", server, "--cmd", "set runtimepath^=" + str(ROOT),
             "-l", str(self.dir / "send.lua"), text],
            env=self.caller_env(caller), capture_output=True, text=True, timeout=30)
        prompt = "Context: example.txt:3\n\n%s\n\n(Shannon prompt via Neovim server %s)" % (
            text, server)
        return result, prompt.encode()

    def received(self, log, end):
        """Waits until `log` ends with `end`, and returns all of it."""
        wait_for(lambda: log.read_bytes().endswith(end), "input in " + log.name)
        return log.read_bytes()

    def test_pastes_into_the_agent_but_not_the_caller(self):
        # The caller also reports itself as Pi and comes first in the window,
        # so only the exclusion of the caller's own terminal keeps the prompt
        # out of it.
        caller, caller_log = self.agent("state=idle:app=pi")
        _, agent_log = self.agent("state=idle:app=pi", beside=caller)

        result, prompt = self.shannon(caller, "Explain this line.\nBriefly.")

        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertEqual(self.received(agent_log, END_PASTE + b"\r"),
                         START_PASTE + prompt + END_PASTE + b"\r")
        self.assertEqual(caller_log.read_bytes(), b"")

    def test_pastes_a_large_prompt_in_pieces(self):
        caller = self.terminal(IDLE)
        _, agent_log = self.agent("state=idle:app=pi", beside=caller)

        # Over 64 KiB once encoded as JSON, with characters of several bytes.
        result, prompt = self.shannon(caller, "Ünïcödé ✓ line\n" * 4000)

        self.assertEqual((result.returncode, result.stderr), (0, ""))
        data = self.received(agent_log, END_PASTE + b"\r")
        self.assertGreater(data.count(START_PASTE), 1)
        self.assertEqual(data.replace(START_PASTE, b"").replace(END_PASTE, b""),
                         prompt + b"\r")

    def test_does_not_send_to_a_blocked_agent(self):
        caller = self.terminal(IDLE)
        agent, agent_log = self.agent("state=blocked:kind=permission:app=claude-code",
                                      beside=caller)

        result, prompt = self.shannon(caller, "Explain this line.")

        self.assertEqual(result.returncode, 0)
        match = re.fullmatch(
            r"shannon: the agent in Rex is waiting for an answer \(permission\)"
            r" \(prompt saved to (\S+)\)\n?", result.stderr)
        self.assertIsNotNone(match, result.stderr)
        saved = Path(match.group(1))
        self.addCleanup(saved.unlink)
        self.assertEqual(saved.read_bytes(), prompt)
        # Shannon pastes before it returns, so a paste would reach the agent
        # before this marker.
        self.rex("block", "call", "-b", agent, "write", json.dumps({"data": "marker"}))
        self.assertEqual(self.received(agent_log, b"marker"), b"marker")

    def test_find_nvim_socket_finds_neovim_beside_the_caller(self):
        caller = self.terminal(IDLE)
        self.terminal(["nvim", "--headless", "--clean"], beside=caller)

        def find():
            result = subprocess.run([str(ROOT / "bin" / "find-nvim-socket")],
                                    env=self.caller_env(caller), capture_output=True,
                                    text=True, timeout=10)
            return result.returncode == 0 and result

        result = wait_for(find, "find-nvim-socket to succeed")
        socket = result.stdout.rstrip("\n")
        self.assertEqual(result.stderr, "")
        servername = subprocess.run(
            ["nvim", "--clean", "--headless", "--server", socket, "--remote-expr", "v:servername"],
            env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(servername.stdout, socket)


if __name__ == "__main__":
    unittest.main()
