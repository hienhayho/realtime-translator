"""Central logging setup. Call configure_logging() once at process startup
(app/main.py module load) before any other app module logs."""
import logging

_CONFIGURED = False


def configure_logging() -> None:
    global _CONFIGURED
    if _CONFIGURED:
        return
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    _CONFIGURED = True
