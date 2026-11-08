import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk


def _application_directory():
    candidates = []
    compiled = globals().get("__compiled__")
    compiled_directory = getattr(compiled, "containing_dir", None)
    if compiled_directory:
        candidates.append(Path(compiled_directory))
    candidates.extend(
        (
            Path(sys.argv[0]).resolve().parent,
            Path(__file__).resolve().parent,
        )
    )
    for candidate in candidates:
        candidate = candidate.resolve()
        if (candidate / "assets").is_dir() or (candidate / "swift").is_dir():
            return candidate
    return Path(__file__).resolve().parent


PROJECT_DIR = _application_directory()
SWIFT_PROJECT_DIR = PROJECT_DIR / "swift"
RELEASE_BUILD = "__compiled__" in globals()


def _swift_game():
    candidates = (
        (SWIFT_PROJECT_DIR / "swift", SWIFT_PROJECT_DIR),
        (SWIFT_PROJECT_DIR / ".build" / "release" / "swift", SWIFT_PROJECT_DIR),
    )
    for executable, working_directory in candidates:
        if executable.is_file():
            return executable, working_directory
    return None


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


def _run_swift_game(arguments):
    game = _swift_game()
    if game is None:
        raise FileNotFoundError(
            "The Swift game executable is missing. Build it with "
            "`cd swift && swift build -c release --product swift`."
        )
    executable, working_directory = game
    subprocess.Popen([str(executable), *arguments], cwd=working_directory)


def _child_command(*arguments):
    executable = Path(sys.argv[0]).resolve()
    if executable.suffix.lower() == ".py":
        return [sys.executable, str(executable), *arguments]
    return [str(executable), *arguments]


class Launcher:
    def __init__(self, root):
        self.root = root
        self.host_process = None
        self.use_swift_version = tk.BooleanVar(value=False)
        root.title("Emoji-ga.me")
        root.resizable(False, False)
        root.protocol("WM_DELETE_WINDOW", self.close)

        frame = ttk.Frame(root, padding=20)
        frame.grid()
        ttk.Label(frame, text="Emoji-ga.me", font=("TkDefaultFont", 18, "bold")).grid(
            row=0, column=0, columnspan=2, pady=(0, 14)
        )
        row = 1
        ttk.Button(frame, text="Matchmaking (Quick Play)", command=self.start_matchmaking).grid(
            row=row, column=0, columnspan=2, sticky="ew", pady=(0, 4)
        )
        row += 1
        if not RELEASE_BUILD:
            ttk.Button(frame, text="Build a world", command=self.start_builder).grid(
                row=row, column=0, columnspan=2, sticky="ew", pady=4
            )
            row += 1
        ttk.Label(frame, text="Host address:").grid(
            row=row, column=0, sticky="w", pady=4
        )
        self.host_entry = ttk.Entry(frame, width=24)
        self.host_entry.insert(0, "127.0.0.1")
        self.host_entry.grid(row=row, column=1, sticky="ew", padx=(8, 0), pady=4)
        row += 1
        ttk.Button(frame, text="Join world", command=self.start_player).grid(
            row=row, column=0, columnspan=2, sticky="ew", pady=4
        )
        row += 1
        ttk.Button(frame, text="Host my world", command=self.start_host).grid(
            row=row, column=0, columnspan=2, sticky="ew", pady=4
        )
        row += 1
        ttk.Separator(frame).grid(
            row=row, column=0, columnspan=2, sticky="ew", pady=8
        )
        row += 1
        ttk.Checkbutton(
            frame,
            text="Use Swift version (experimental)",
            variable=self.use_swift_version,
        ).grid(row=row, column=0, columnspan=2, sticky="w", pady=4)

    def _start_process(self, *arguments):
        try:
            if self.use_swift_version.get() and arguments[0] in ("--builder", "--player"):
                _run_swift_game(arguments)
            else:
                subprocess.Popen(_child_command(*arguments), cwd=PROJECT_DIR)
        except OSError as error:
            messagebox.showerror("Could not start game", str(error), parent=self.root)

    def start_matchmaking(self):
        from HostServer import find_match
        found = find_match(timeout=0.6)
        if found:
            host, port = found
            messagebox.showinfo("Match Found!", f"Found active match at {host}! Joining...", parent=self.root)
            self._start_process("--player", host)
        else:
            self.start_host()
            self.root.after(500, lambda: self._start_process("--player", "127.0.0.1"))

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
            f"Your world is available on port {self._default_port()}.",
            parent=self.root,
        )

    @staticmethod
    def _default_port():
        from HostServer import DEFAULT_PORT

        return DEFAULT_PORT

    def close(self):
        if self.host_process is not None and self.host_process.poll() is None:
            self.host_process.terminate()
        self.root.destroy()


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    launcher = None
    try:
        if arguments:
            mode, *mode_arguments = arguments
            if mode == "--builder" and not mode_arguments and not RELEASE_BUILD:
                _run_builder()
                return 0
            if mode == "--player" and len(mode_arguments) == 1:
                _run_player(mode_arguments[0])
                return 0
            if mode == "--host-server" and not mode_arguments:
                _run_host()
                return 0
            usage = "Usage: launcher.py [--player HOST | --host-server]" if RELEASE_BUILD else (
                "Usage: launcher.py [--builder | --player HOST | --host-server]"
            )
            raise SystemExit(usage)

        root = tk.Tk()
        launcher = Launcher(root)
        root.mainloop()
        return 0
    except KeyboardInterrupt:
        print("\nStopping Emoji-ga.me...")
        if launcher is not None:
            launcher.close()
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
