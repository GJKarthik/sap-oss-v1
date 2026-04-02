"""
database.py — persistent store lifecycle helpers.
The API uses the configured persistent store backend from store.py.
"""

from .store import get_store


async def init_database() -> None:
    """Initialise the configured persistent store backend."""
    get_store().initialise()


async def close_database() -> None:
    """Close the persistent store lifecycle."""
    get_store().close()


async def get_session():
    """Retained for import compatibility. Use get_store() instead."""
    yield get_store()
