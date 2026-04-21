"""Built-in protocol profiles.

Each profile module exports a :class:`orion.constellation.Constellation`
describing the contracts, their deploy order, and post-deploy role
grants. The CLI dispatches ``--profile <name>`` to
``orion.profiles.<name>``.
"""
