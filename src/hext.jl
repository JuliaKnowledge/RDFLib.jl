# ─── HEXT (Hextuples) Compatibility Aliases ─────────────────────────
# HEXT in Python rdflib is the Hextuples format. These aliases provide
# compatibility with code that references the HEXT name.

"""HEXT is the Hextuples format — alias for convenience."""
const HEXTFormat = Nothing  # no separate format type; use hextuples functions directly

"""Serialize a graph to HEXT (Hextuples) format."""
const serialize_hext = serialize_hextuples

"""Parse HEXT (Hextuples) string into a Dataset."""
const parse_hext = parse_hextuples

"""Parse HEXT (Hextuples) string and add triples to an existing graph."""
const parse_hext! = parse_hextuples!
