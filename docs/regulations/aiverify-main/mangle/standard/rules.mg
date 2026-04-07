# AI Verify migration rules

Decl parity_ready(component: /string).
Decl migrated(component: /string).
Decl bridge_enabled(component: /string).

parity_ready(Component) :-
    migrated(Component),
    bridge_enabled(Component),
    service("aiverify").
