"""Small stdlib-only validation boundary for opt-in research runtimes."""

import importlib
import importlib.metadata
import math


class AdapterDependencyError(RuntimeError):
    """The optional adapter runtime is absent or differs from the reviewed pin."""


def integer(name: str, value, minimum: int, maximum: int) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer in [{minimum}, {maximum}]")
    return value


def probability(name: str, value) -> float:
    if (
        type(value) not in (int, float)
        or not math.isfinite(value)
        or not 0 <= value <= 1
    ):
        raise ValueError(f"{name} must be a finite probability in [0, 1]")
    return float(value)


def require_runtime(module: str, expected: str, extra: str):
    install = f"uv sync --frozen --extra {extra} --python 3.12"
    try:
        installed = importlib.metadata.version(module)
    except importlib.metadata.PackageNotFoundError as error:
        raise AdapterDependencyError(
            f"Optional runtime {module}=={expected} is missing. Run `{install}` "
            "from experiments/economic_simulation."
        ) from error
    if installed != expected:
        raise AdapterDependencyError(
            f"Expected reviewed runtime {module}=={expected}; found {installed}. "
            f"Run `{install}` from experiments/economic_simulation."
        )
    return importlib.import_module(module)
