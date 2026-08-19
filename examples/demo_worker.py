#!/usr/bin/env python3
"""Stand-in for the real CLI.

Deployed automatically when app_repo_url is left empty, so the whole pipeline -
systemd restart, CloudWatch log shipping, error alarm, watchdog, Claude
diagnosis - can be proven end to end before your own code is wired in.

It logs a heartbeat every 30s and understands two env vars for drills:

    DEMO_CRASH_AFTER=60    exit non-zero after 60s   (tests auto-restart)
    DEMO_ERROR_EVERY=300   log a traceback every 5m  (tests the error alarm)
"""

import logging
import os
import signal
import sys
import threading
import time

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    stream=sys.stdout,
)
log = logging.getLogger("demo-worker")

CRASH_AFTER = int(os.environ.get("DEMO_CRASH_AFTER", "0"))
ERROR_EVERY = int(os.environ.get("DEMO_ERROR_EVERY", "0"))

# An Event, not a bool. `time.sleep(30)` is NOT interruptible by a signal
# handler, so a plain flag means systemd waits the full sleep before the
# process exits - which turns every redeploy into a 30s stall and every
# stop into a possible SIGKILL. Waiting on an Event wakes instantly.
_stop_event = threading.Event()


def _stop(signum, _frame):
    log.info("received signal %s, shutting down cleanly", signum)
    _stop_event.set()


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


def main() -> int:
    started = time.monotonic()
    tick = 0
    log.info("demo worker started (pid=%s crash_after=%s error_every=%s)",
             os.getpid(), CRASH_AFTER, ERROR_EVERY)

    while not _stop_event.is_set():
        tick += 1
        elapsed = int(time.monotonic() - started)
        log.info("heartbeat tick=%s uptime=%ss", tick, elapsed)

        if ERROR_EVERY and elapsed and elapsed % ERROR_EVERY < 30:
            try:
                raise RuntimeError("synthetic failure for alarm testing")
            except RuntimeError:
                log.exception("caught a synthetic error")

        if CRASH_AFTER and elapsed >= CRASH_AFTER:
            log.error("DEMO_CRASH_AFTER reached - exiting 1 on purpose")
            return 1

        if _stop_event.wait(30):
            break

    log.info("stopped cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
