# Optional simulation diagnostics adapter

Add exactly one live Node to `godot_mcp_simulation_adapter`. It may be a scene
node or autoload. No settlement node names or game classes are hardcoded in the
addon. Missing/multiple adapters are errors.

Implement these methods:

- `mcp_simulation_capabilities() -> Dictionary`: `supported_sections` (subset of
  jobs/reservations/inventories/paths/power/needs) and `can_advance_ticks: bool`.
- `mcp_simulation_snapshot(filters: Dictionary) -> Dictionary`: return
  `{schema_version:1, tick:<authoritative integer>, data:{section:records}}`.
  Filters contain supported requested sections and optional entity_ids. An empty
  sections list requests no records; omitted sections requests all supported ones.

Produce a coherent snapshot on the game main thread at one simulation boundary.
Records must use stable entity IDs and JSON-native values (convert vectors to
arrays, nodes/resources to IDs). Cycles, nonfinite floats and opaque objects are
rejected; nesting and total value count are bounded. Do not mutate or advance the
simulation during a snapshot. Implement entity filtering in the adapter.

The tool wraps the snapshot with capabilities and unsupported_sections. It never
fills unavailable systems with fabricated records. Missing a section that the
adapter advertised as supported is an error. Record fields beyond stable IDs are
game-defined; see `examples/scripts/simulation_demo.gd` for a tiny linked fixture.
It has settler-1, job-1, reservation-1, wood-1 and workbench-1 records across the
six sections, all derived from one integer tick. Empty records for an entity that
does not exist are different from an unsupported section.

This repository does not contain the user's settlement simulation. Integrating
its real job scheduler, reservations, inventories, pathfinding, power and needs
requires a separate change in that game repository.
