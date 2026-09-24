import subprocess


def push():
    subprocess.run(["gnmic", "-a", "leaf01", "set"])
