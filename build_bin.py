import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent
OUTPUT_NAME = "emoji-ga_me.exe" if os.name == "nt" else "emoji-ga_me"


def main():
    if importlib.util.find_spec("nuitka") is None:
        raise SystemExit(
            "Nuitka is not installed. Install it with "
            f"{sys.executable} -m pip install nuitka"
        )

    if sys.platform.startswith("linux") and shutil.which("patchelf") is None:
        raise SystemExit(
            "Nuitka onefile builds on Linux require patchelf. "
            "Install it with: sudo apt install patchelf"
        )

    command = [
        sys.executable,
        "-m",
        "nuitka",
        "--onefile",
        "--enable-plugin=tk-inter",
        f"--output-filename={OUTPUT_NAME}",
        "--include-data-dir=assets=assets",
        "--include-data-files=world.json=world.json",
        "launcher.py",
    ]
    result = subprocess.run(command, cwd=PROJECT_DIR, check=False)
    if result.returncode:
        raise SystemExit(result.returncode)
    print(f"Built {PROJECT_DIR / OUTPUT_NAME}")


if __name__ == "__main__":
    main()
