"""Opt-in research adapters with lazy third-party imports.

These demonstrations return independent JSON records. They do not choose the
core simulator's policies or claim that an agreement was physically fulfilled.
"""

from .mesa import run_mesa_demo
from .negmas import run_negotiation
from .validation import AdapterDependencyError

__all__ = ["AdapterDependencyError", "run_mesa_demo", "run_negotiation"]
