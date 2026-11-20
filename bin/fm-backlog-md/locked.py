import fcntl
import os
import sys

root, lock_name, script, *args = sys.argv[1:]
try:
    fd = os.open(os.path.join(root, lock_name), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.set_inheritable(fd, True)
    os.execvp("node", ["node", script, root, *args])
except OSError as error:
    sys.exit(f"fm-tasks-axi: cannot run the backlog command: {error}")
