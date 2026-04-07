# Bridge-mode declarations while migrating Python modules to Zig/Mojo.

Decl bridge_mode(mode: /string).
Decl module_owner(module: /string, owner: /string).

bridge_mode("python_compat").
module_owner("entrypoints.cli", "zig").
module_owner("domain.entities", "zig").
module_owner("runtime.metrics_primitives", "mojo").
