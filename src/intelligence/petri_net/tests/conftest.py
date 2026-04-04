"""Configure test imports to work with the package's relative imports."""
import sys
import os

# Add the parent of petri_net to sys.path so that `import petri_net.core` works
# and the relative imports inside the package resolve correctly.
pkg_parent = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if pkg_parent not in sys.path:
    sys.path.insert(0, pkg_parent)
