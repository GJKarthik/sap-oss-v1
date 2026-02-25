# rules/routing.mg

# Declare the extensional predicate that will be populated dynamically.
# Score is an integer in range [0, 100] representing percentage confidence.
Decl es_cache_lookup(Query, Answer, Score) descr [extensional()].

# A query is cached if ES returns a match with score >= 95 (out of 100).
is_cached(Query) :-
    es_cache_lookup(Query, _, Score),
    Score >= 95.

# Resolution: cached path
resolve(Query, Answer, "cache", Score) :-
    is_cached(Query),
    es_cache_lookup(Query, Answer, Score).
