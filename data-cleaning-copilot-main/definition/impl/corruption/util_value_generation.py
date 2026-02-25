import random
import re
import string
from typing import Final
from pandas.api import types as pdt

__all__ = ["out_of_range_value", "pattern_violation_value"]


def out_of_range_value(
    dtype,  # pandas/numpy dtype or numpy scalar type
    min_bound: float | None,
    max_bound: float | None,
    rand: random.Random,
) -> float | int:
    """Generate a numeric value outside the range *(min_bound, max_bound)*.

    If both bounds are provided, the value will be either lower than *min_bound* or
    higher than *max_bound* (chosen at random). If only one bound is provided the
    value will exceed that single bound. If neither is present, an extreme value
    (±1e12) is returned.
    """
    if min_bound is not None and max_bound is not None:
        target = max_bound + 1 if rand.random() < 0.5 else min_bound - 1
    elif max_bound is not None:
        target = max_bound + 1
    elif min_bound is not None:
        target = min_bound - 1
    else:
        target = 1e12
        if rand.random() < 0.5:
            target *= -1

    # Preserve integer vs float nature
    return int(target) if pdt.is_integer_dtype(dtype) else float(target)


def pattern_violation_value(pattern: str, rand: random.Random) -> str:
    """Return a random string that does **not** match *pattern*.

    Parameters
    ----------
    pattern : str
        Regular-expression pattern to violate.
    rand : random.Random
        RNG instance used for reproducibility.

    Raises
    ------
    ValueError
        If *pattern* is not a valid regular expression.
    RuntimeError
        If no violating string could be generated within 1000 attempts.
    """
    try:
        regex: Final[re.Pattern[str]] = re.compile(pattern)
    except re.error as exc:
        raise ValueError(f"Invalid regular expression `{pattern}`: {exc}") from exc

    fullmatch = regex.fullmatch  # local alias for speed

    for candidate in ("A", "1", "!", " "):
        if fullmatch(candidate) is None:
            return candidate

    alphabet: Final[str] = string.ascii_letters + string.digits + string.punctuation + " "
    max_len: Final[int] = 30  # practical upper bound
    max_attempt: Final[int] = 1_000

    for _ in range(max_attempt):
        length = rand.randint(1, max_len)
        candidate = "".join(rand.choice(alphabet) for _ in range(length))
        if fullmatch(candidate) is None:
            return candidate

    raise RuntimeError(f"Could not generate a value that violates pattern {pattern!r}")
