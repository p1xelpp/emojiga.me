import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk


PROJECT_DIR = Path(__file__).resolve().parent


def _run_builder():
    from BaseWorldEngineBuilder import BaseWorldEngine

    world = BaseWorldEngine()
    world.test_plane()
    world.start()


def _run_player(host):
    from BaseWorldEnginePlayer import BaseWorldEnginePlayer
    from HostServer import DEFAULT_PORT, WorldClient

    network = WorldClient(host=host, port=DEFAULT_PORT)
    world = BaseWorldEnginePlayer(host=host, network=network)
    world.test_plane()
    world.start()


def _run_host():
    from HostServer import HostServer

    HostServer().serve_forever()


def _child_command(*arguments):
    executable = Path(sys.argv[0]).resolve()
    if executable.suffix.lower() == ".py":
        return [sys.executable, str(executable), *arguments]
    return [str(executable), *arguments]


class Launcher:
    def __init__(self, root):
        self.root = root
        self.host_process = None
        root.title("Emoji-ga_me")
        root.resizable(False, False)
        root.protocol("WM_DELETE_WINDOW", self.close)

        frame = ttk.Frame(root, padding=20)
        frame.grid()
        ttk.Label(frame, text="Emoji-ga_me", font=("TkDefaultFont", 18, "bold")).grid(
            row=0, column=0, columnspan=2, pady=(0, 14)
        )

        ttk.Button(frame, text="Build a world", command=self.start_builder).grid(
            row=1, column=0, columnspan=2, sticky="ew", pady=4
        )

        ttk.Label(frame, text="Host address:").grid(
            row=2, column=0, sticky="w", pady=4
        )
        self.host_entry = ttk.Entry(frame, width=24)
        self.host_entry.insert(0, "127.0.0.1")
        self.host_entry.grid(row=2, column=1, sticky="ew", padx=(8, 0), pady=4)
        ttk.Button(frame, text="Join world", command=self.start_player).grid(
            row=3, column=0, columnspan=2, sticky="ew", pady=4
        )
        ttk.Button(frame, text="Host my world", command=self.start_host).grid(
            row=4, column=0, columnspan=2, sticky="ew", pady=4
        )

    def _start_process(self, *arguments):
        try:
            subprocess.Popen(_child_command(*arguments), cwd=PROJECT_DIR)
        except OSError as error:
            messagebox.showerror("Could not start game", str(error), parent=self.root)

    def start_builder(self):
        self._start_process("--builder")

    def start_player(self):
        host = self.host_entry.get().strip()
        if not host:
            messagebox.showerror("Missing host", "Enter a host address.", parent=self.root)
            return
        self._start_process("--player", host)

    def start_host(self):
        if self.host_process is not None and self.host_process.poll() is None:
            messagebox.showinfo("Host running", "Your world is already being hosted.", parent=self.root)
            return
        try:
            self.host_process = subprocess.Popen(
                _child_command("--host-server"),
                cwd=PROJECT_DIR,
            )
        except OSError as error:
            messagebox.showerror("Could not start host", str(error), parent=self.root)
            return
        messagebox.showinfo(
            "World hosted",
            "Your world is available on port 27016.",
            parent=self.root,
        )

    def close(self):
        if self.host_process is not None and self.host_process.poll() is None:
            self.host_process.terminate()
        self.root.destroy()


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if arguments:
        mode, *mode_arguments = arguments
        if mode == "--builder" and not mode_arguments:
            _run_builder()
            return 0
        if mode == "--player" and len(mode_arguments) == 1:
            _run_player(mode_arguments[0])
            return 0
        if mode == "--host-server" and not mode_arguments:
            _run_host()
            return 0
        raise SystemExit("Usage: launcher.py [--builder | --player HOST | --host-server]")

    root = tk.Tk()
    Launcher(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
