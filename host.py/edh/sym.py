__all__ = [
    "Symbol",
]

from . import log

logger = log.get_logger(__name__)


class Symbol:
    __slots__ = ("repr",)

    def __init__(self, repr_: str):
        self.repr = repr_

    def __repr__(self):
        return self.repr

    __str__ = __repr__

