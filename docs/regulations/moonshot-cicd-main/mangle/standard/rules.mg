# Moonshot migration rules

Decl parity_ready(component: /string).
Decl migrated(component: /string).

parity_ready(Component) :-
    migrated(Component),
    service("moonshot-cicd").
