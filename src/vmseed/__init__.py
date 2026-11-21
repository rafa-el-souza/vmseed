"""vmseed: provision hardened local VMs from verified cloud images, and prove it.

The package follows a functional core and an imperative shell
(docs/spec/01-architecture.md): building a plan is pure, and only the ``host``
and ``ops`` layers perform effects.
"""

from importlib.metadata import version

__version__ = version("vmseed")
