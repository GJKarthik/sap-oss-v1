# AI Verify Migration Mangle Layer

This directory captures migration metadata for the AI Verify Zig/Mojo port.

## Files

- `standard/facts.mg`: service/runtime/component facts.
- `standard/rules.mg`: parity derivation rules.
- `domain/parity_bridge.mg`: bridge mode + module ownership declarations.

These files are intended to be imported into broader compliance and migration
reasoning pipelines while Python modules are incrementally ported.
