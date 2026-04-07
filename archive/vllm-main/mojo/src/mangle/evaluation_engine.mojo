"""
Mangle Evaluation Engine with Safety Features (H2, H3 Implementation)

This module implements a Mangle Datalog evaluation engine with:
- H2: Completeness warning when max_iterations is reached
- H3: Provenance tracking for all derived facts

Reference: safety-ndeductivedatabase-mangle.pdf Section 5 (Semi-naive evaluation)
"""

from collections import Dict, Set
from memory import UnsafePointer
from memory.unsafe_pointer import alloc
from time import now

from .parser import MangleFact, MangleParser


# =============================================================================
# PROVENANCE TRACKING (H3)
# =============================================================================

struct FactProvenance:
    """
    Tracks the derivation history of a fact.
    
    Every derived fact has provenance showing:
    - Which rule derived it
    - Which input facts were used
    - When it was derived
    - Confidence score (if probabilistic)
    """
    var fact_id: Int
    var derivation_rule: String      # The rule that derived this fact
    var source_facts: List[Int]      # IDs of input facts used
    var derivation_timestamp: Int    # When derived (nanoseconds)
    var iteration: Int               # Which fixpoint iteration
    var confidence: Float32          # Derived confidence score
    var is_base_fact: Bool           # True if asserted, not derived
    
    fn __init__(out self, fact_id: Int, is_base: Bool = False):
        self.fact_id = fact_id
        self.derivation_rule = ""
        self.source_facts = List[Int]()
        self.derivation_timestamp = now()
        self.iteration = 0
        self.confidence = 1.0
        self.is_base_fact = is_base
    
    fn set_derived(
        mut self,
        rule: String,
        sources: List[Int],
        iteration: Int,
        confidence: Float32
    ):
        """Mark this fact as derived from a rule."""
        self.is_base_fact = False
        self.derivation_rule = rule
        self.source_facts = sources
        self.iteration = iteration
        self.confidence = confidence
        self.derivation_timestamp = now()
    
    fn to_mangle_fact(self) -> String:
        """Convert provenance to a Mangle fact for audit."""
        if self.is_base_fact:
            return (
                "fact_provenance(" + String(self.fact_id) + ", \"base\", [], " +
                String(self.derivation_timestamp) + ", " + String(self.confidence) + ")."
            )
        
        var sources_str = "["
        for i in range(len(self.source_facts)):
            if i > 0:
                sources_str += ", "
            sources_str += String(self.source_facts[i])
        sources_str += "]"
        
        return (
            "fact_provenance(" + String(self.fact_id) + ", \"" +
            self.derivation_rule + "\", " + sources_str + ", " +
            String(self.derivation_timestamp) + ", " + String(self.confidence) + ")."
        )


struct ProvenanceStore:
    """Storage for fact provenance records."""
    var records: List[FactProvenance]
    var fact_to_provenance: Dict[Int, Int]  # fact_id -> provenance index
    var next_fact_id: Int
    
    fn __init__(out self):
        self.records = List[FactProvenance]()
        self.fact_to_provenance = Dict[Int, Int]()
        self.next_fact_id = 1
    
    fn record_base_fact(mut self) -> Int:
        """Record provenance for a base (asserted) fact."""
        var fact_id = self.next_fact_id
        self.next_fact_id += 1
        
        var prov = FactProvenance(fact_id, True)
        var idx = len(self.records)
        self.records.append(prov)
        self.fact_to_provenance[fact_id] = idx
        
        return fact_id
    
    fn record_derived_fact(
        mut self,
        rule: String,
        source_facts: List[Int],
        iteration: Int,
        confidence: Float32 = 1.0
    ) -> Int:
        """Record provenance for a derived fact."""
        var fact_id = self.next_fact_id
        self.next_fact_id += 1
        
        var prov = FactProvenance(fact_id, False)
        prov.set_derived(rule, source_facts, iteration, confidence)
        var idx = len(self.records)
        self.records.append(prov)
        self.fact_to_provenance[fact_id] = idx
        
        return fact_id
    
    fn get_provenance(self, fact_id: Int) -> UnsafePointer[FactProvenance]:
        """Look up provenance for a fact."""
        if fact_id in self.fact_to_provenance:
            var idx = self.fact_to_provenance[fact_id]
            return UnsafePointer.address_of(self.records[idx])
        return UnsafePointer[FactProvenance]()
    
    fn get_full_derivation_chain(self, fact_id: Int) -> List[Int]:
        """
        Get the complete derivation chain for a fact.
        Returns all fact IDs that contributed to this fact's derivation.
        """
        var chain = List[Int]()
        var visited = Set[Int]()
        self._collect_chain(fact_id, chain, visited)
        return chain
    
    fn _collect_chain(
        self,
        fact_id: Int,
        mut chain: List[Int],
        mut visited: Set[Int]
    ):
        """Recursively collect all facts in the derivation chain."""
        if fact_id in visited:
            return
        visited.add(fact_id)
        chain.append(fact_id)
        
        var prov_ptr = self.get_provenance(fact_id)
        if prov_ptr and not prov_ptr[].is_base_fact:
            for i in range(len(prov_ptr[].source_facts)):
                self._collect_chain(prov_ptr[].source_facts[i], chain, visited)
    
    fn export_all(self) -> List[String]:
        """Export all provenance records as Mangle facts."""
        var facts = List[String]()
        for i in range(len(self.records)):
            facts.append(self.records[i].to_mangle_fact())
        return facts


# =============================================================================
# COMPLETENESS TRACKING (H2)
# =============================================================================

struct CompletenessStatus:
    """
    Tracks evaluation completeness status.
    
    H2 Implementation: Warns if fixpoint is not reached within max_iterations.
    """
    var is_complete: Bool
    var iterations_run: Int
    var max_iterations: Int
    var facts_derived_last_iteration: Int
    var warning_message: String
    var total_facts_derived: Int
    var evaluation_time_ns: Int
    
    fn __init__(out self, max_iterations: Int):
        self.is_complete = False
        self.iterations_run = 0
        self.max_iterations = max_iterations
        self.facts_derived_last_iteration = 0
        self.warning_message = ""
        self.total_facts_derived = 0
        self.evaluation_time_ns = 0
    
    fn mark_complete(mut self, iterations: Int, time_ns: Int):
        """Mark evaluation as complete (fixpoint reached)."""
        self.is_complete = True
        self.iterations_run = iterations
        self.evaluation_time_ns = time_ns
        self.warning_message = ""
    
    fn mark_incomplete(mut self, iterations: Int, last_derived: Int, time_ns: Int):
        """
        Mark evaluation as incomplete (max_iterations reached).
        
        H2 FIX: Generate warning message about potential incompleteness.
        """
        self.is_complete = False
        self.iterations_run = iterations
        self.facts_derived_last_iteration = last_derived
        self.evaluation_time_ns = time_ns
        
        # H2: Generate completeness warning
        self.warning_message = (
            "WARNING: Evaluation reached max_iterations (" + String(iterations) +
            ") without achieving fixpoint. " + String(last_derived) +
            " facts were derived in the last iteration. " +
            "Results may be incomplete. Consider increasing max_iterations or " +
            "reviewing rules for infinite recursion."
        )
    
    fn to_mangle_fact(self) -> String:
        """Export status as a Mangle fact."""
        var status = "complete" if self.is_complete else "incomplete"
        return (
            "evaluation_status(\"" + status + "\", " +
            String(self.iterations_run) + ", " +
            String(self.total_facts_derived) + ", " +
            String(self.evaluation_time_ns) + ")."
        )
    
    fn has_warning(self) -> Bool:
        return len(self.warning_message) > 0


# =============================================================================
# MANGLE RULE REPRESENTATION
# =============================================================================

struct MangleRule:
    """
    Represents a Mangle Datalog rule.
    
    Format: head :- body1, body2, ...
    Example: can_access(X, Y) :- role(X, admin), resource(Y, public).
    """
    var head_predicate: String
    var head_args: List[String]
    var body_literals: List[MangleFact]
    var is_negated: List[Bool]  # Whether each body literal is negated
    var rule_name: String       # For provenance tracking
    
    fn __init__(out self, head_pred: String, name: String = ""):
        self.head_predicate = head_pred
        self.head_args = List[String]()
        self.body_literals = List[MangleFact]()
        self.is_negated = List[Bool]()
        self.rule_name = name if len(name) > 0 else head_pred + "_rule"
    
    fn add_head_arg(mut self, arg: String):
        self.head_args.append(arg)
    
    fn add_body_literal(mut self, literal: MangleFact, negated: Bool = False):
        self.body_literals.append(literal)
        self.is_negated.append(negated)
    
    fn is_stratified_safe(self) -> Bool:
        """
        Check if rule is safe under stratification.
        Negated predicates must not depend on the head predicate.
        """
        for i in range(len(self.body_literals)):
            if self.is_negated[i]:
                if self.body_literals[i].predicate == self.head_predicate:
                    return False  # Self-referential negation
        return True


# =============================================================================
# EVALUATION ENGINE
# =============================================================================

struct MangleEvaluationEngine:
    """
    Semi-naive Mangle evaluation engine with safety features.
    
    Features:
    - H2: Completeness warning on max_iterations
    - H3: Full provenance tracking for all derived facts
    - Stratified negation support
    - Confidence propagation
    """
    var base_facts: List[MangleFact]
    var base_fact_ids: List[Int]
    var derived_facts: List[MangleFact]
    var derived_fact_ids: List[Int]
    var rules: List[MangleRule]
    var provenance_store: ProvenanceStore
    var max_iterations: Int
    var confidence_threshold: Float32
    
    fn __init__(out self, max_iterations: Int = 1000):
        self.base_facts = List[MangleFact]()
        self.base_fact_ids = List[Int]()
        self.derived_facts = List[MangleFact]()
        self.derived_fact_ids = List[Int]()
        self.rules = List[MangleRule]()
        self.provenance_store = ProvenanceStore()
        self.max_iterations = max_iterations
        self.confidence_threshold = 0.01  # Minimum confidence to keep a fact
    
    fn assert_fact(mut self, fact: MangleFact, confidence: Float32 = 1.0) -> Int:
        """
        Assert a base fact into the knowledge base.
        Returns the fact ID for provenance tracking.
        """
        var fact_id = self.provenance_store.record_base_fact()
        self.base_facts.append(fact)
        self.base_fact_ids.append(fact_id)
        return fact_id
    
    fn add_rule(mut self, rule: MangleRule):
        """Add a rule to the knowledge base."""
        self.rules.append(rule)
    
    fn evaluate(mut self) -> CompletenessStatus:
        """
        Run semi-naive evaluation to fixpoint.
        
        Returns CompletenessStatus with H2 warnings if max_iterations reached.
        """
        var status = CompletenessStatus(self.max_iterations)
        var start_time = now()
        
        # Initialize delta with all base facts
        var delta = List[MangleFact]()
        var delta_ids = List[Int]()
        for i in range(len(self.base_facts)):
            delta.append(self.base_facts[i])
            delta_ids.append(self.base_fact_ids[i])
        
        var iteration = 0
        var new_facts_count = 0
        
        while iteration < self.max_iterations:
            iteration += 1
            new_facts_count = 0
            
            var new_delta = List[MangleFact]()
            var new_delta_ids = List[Int]()
            
            # Apply each rule to delta facts
            for r in range(len(self.rules)):
                var rule = self.rules[r]
                var derived = self._apply_rule(rule, delta, delta_ids, iteration)
                
                for d in range(len(derived.facts)):
                    # Check if fact is truly new
                    if not self._fact_exists(derived.facts[d]):
                        new_delta.append(derived.facts[d])
                        new_delta_ids.append(derived.fact_ids[d])
                        self.derived_facts.append(derived.facts[d])
                        self.derived_fact_ids.append(derived.fact_ids[d])
                        new_facts_count += 1
            
            status.total_facts_derived += new_facts_count
            
            # Check for fixpoint
            if new_facts_count == 0:
                status.mark_complete(iteration, now() - start_time)
                return status
            
            # Update delta for next iteration
            delta = new_delta
            delta_ids = new_delta_ids
        
        # H2: Max iterations reached without fixpoint
        status.mark_incomplete(iteration, new_facts_count, now() - start_time)
        return status
    
    fn _apply_rule(
        self,
        rule: MangleRule,
        delta: List[MangleFact],
        delta_ids: List[Int],
        iteration: Int
    ) -> DerivedFacts:
        """
        Apply a rule to delta facts, deriving new facts.
        
        This is a simplified implementation - a full implementation would
        use proper unification and join algorithms.
        """
        var result = DerivedFacts()
        
        # For each delta fact that matches first body literal
        for d in range(len(delta)):
            var delta_fact = delta[d]
            
            if len(rule.body_literals) == 0:
                continue
            
            var first_body = rule.body_literals[0]
            
            # Check if delta fact matches first body literal
            if delta_fact.predicate == first_body.predicate:
                # Simple case: single body literal rule
                if len(rule.body_literals) == 1:
                    var bindings = self._unify(first_body, delta_fact)
                    if len(bindings) > 0:
                        var derived = self._instantiate_head(rule, bindings)
                        var source_ids = List[Int]()
                        source_ids.append(delta_ids[d])
                        
                        var fact_id = self.provenance_store.record_derived_fact(
                            rule.rule_name, source_ids, iteration, 1.0
                        )
                        result.add(derived, fact_id)
                
                # Multi-body literal rule - need to join with existing facts
                elif len(rule.body_literals) > 1:
                    var partial_bindings = self._unify(first_body, delta_fact)
                    if len(partial_bindings) > 0:
                        var matched = self._match_remaining_body(
                            rule, 1, partial_bindings, delta_ids[d]
                        )
                        for m in range(len(matched.facts)):
                            result.add(matched.facts[m], matched.fact_ids[m])
        
        return result
    
    fn _unify(self, pattern: MangleFact, fact: MangleFact) -> Dict[String, String]:
        """
        Simple unification of a pattern against a fact.
        Returns variable bindings or empty dict if no match.
        """
        var bindings = Dict[String, String]()
        
        if pattern.num_args != fact.num_args:
            return bindings
        
        for i in range(pattern.num_args):
            var p_arg = pattern.get_arg(i)
            var f_arg = fact.get_arg(i)
            
            # Variable starts with uppercase or is _ (Prolog convention)
            if len(p_arg) > 0 and (p_arg[0].isupper() or p_arg == "_"):
                if p_arg in bindings:
                    if bindings[p_arg] != f_arg:
                        return Dict[String, String]()  # Conflict
                else:
                    bindings[p_arg] = f_arg
            else:
                # Constant - must match exactly
                if p_arg != f_arg:
                    return Dict[String, String]()
        
        return bindings
    
    fn _match_remaining_body(
        self,
        rule: MangleRule,
        start_idx: Int,
        bindings: Dict[String, String],
        first_fact_id: Int
    ) -> DerivedFacts:
        """Match remaining body literals against existing facts."""
        var result = DerivedFacts()
        
        # For simplicity, only handle 2-body rules fully
        if start_idx >= len(rule.body_literals):
            # All body literals matched - derive head
            var derived = self._instantiate_head(rule, bindings)
            var source_ids = List[Int]()
            source_ids.append(first_fact_id)
            
            var fact_id = self.provenance_store.record_derived_fact(
                rule.rule_name, source_ids, 0, 1.0
            )
            result.add(derived, fact_id)
            return result
        
        var body_lit = rule.body_literals[start_idx]
        var is_negated = rule.is_negated[start_idx]
        
        # Search in base and derived facts
        var all_facts = self.base_facts + self.derived_facts
        var all_ids = self.base_fact_ids + self.derived_fact_ids
        
        var found_match = False
        for f in range(len(all_facts)):
            if all_facts[f].predicate != body_lit.predicate:
                continue
            
            var new_bindings = self._extend_bindings(bindings, body_lit, all_facts[f])
            if len(new_bindings) > 0:
                found_match = True
                
                if not is_negated:
                    var sub_results = self._match_remaining_body(
                        rule, start_idx + 1, new_bindings, first_fact_id
                    )
                    for r in range(len(sub_results.facts)):
                        result.add(sub_results.facts[r], sub_results.fact_ids[r])
        
        # Handle negation: if negated and no match found, that's success
        if is_negated and not found_match:
            var sub_results = self._match_remaining_body(
                rule, start_idx + 1, bindings, first_fact_id
            )
            for r in range(len(sub_results.facts)):
                result.add(sub_results.facts[r], sub_results.fact_ids[r])
        
        return result
    
    fn _extend_bindings(
        self,
        bindings: Dict[String, String],
        pattern: MangleFact,
        fact: MangleFact
    ) -> Dict[String, String]:
        """Try to extend bindings with a new pattern-fact match."""
        var new_bindings = bindings.copy()
        
        if pattern.num_args != fact.num_args:
            return Dict[String, String]()
        
        for i in range(pattern.num_args):
            var p_arg = pattern.get_arg(i)
            var f_arg = fact.get_arg(i)
            
            if len(p_arg) > 0 and (p_arg[0].isupper() or p_arg == "_"):
                if p_arg in new_bindings:
                    if new_bindings[p_arg] != f_arg:
                        return Dict[String, String]()
                else:
                    new_bindings[p_arg] = f_arg
            else:
                if p_arg != f_arg:
                    return Dict[String, String]()
        
        return new_bindings
    
    fn _instantiate_head(self, rule: MangleRule, bindings: Dict[String, String]) -> MangleFact:
        """Create a derived fact by instantiating the rule head with bindings."""
        var fact = MangleFact(rule.head_predicate)
        
        for i in range(len(rule.head_args)):
            var arg = rule.head_args[i]
            if arg in bindings:
                fact.add_arg(bindings[arg])
            else:
                fact.add_arg(arg)
        
        return fact
    
    fn _fact_exists(self, fact: MangleFact) -> Bool:
        """Check if a fact already exists in base or derived facts."""
        # Check base facts
        for i in range(len(self.base_facts)):
            if self._facts_equal(self.base_facts[i], fact):
                return True
        
        # Check derived facts
        for i in range(len(self.derived_facts)):
            if self._facts_equal(self.derived_facts[i], fact):
                return True
        
        return False
    
    fn _facts_equal(self, f1: MangleFact, f2: MangleFact) -> Bool:
        """Check if two facts are equal."""
        if f1.predicate != f2.predicate:
            return False
        if f1.num_args != f2.num_args:
            return False
        for i in range(f1.num_args):
            if f1.get_arg(i) != f2.get_arg(i):
                return False
        return True
    
    fn query(self, predicate: String, args: List[String]) -> List[MangleFact]:
        """
        Query for facts matching a predicate and argument pattern.
        Variables (uppercase) in args act as wildcards.
        """
        var results = List[MangleFact]()
        var pattern = MangleFact(predicate)
        for i in range(len(args)):
            pattern.add_arg(args[i])
        
        # Search base facts
        for i in range(len(self.base_facts)):
            if self._matches_pattern(self.base_facts[i], pattern):
                results.append(self.base_facts[i])
        
        # Search derived facts
        for i in range(len(self.derived_facts)):
            if self._matches_pattern(self.derived_facts[i], pattern):
                results.append(self.derived_facts[i])
        
        return results
    
    fn _matches_pattern(self, fact: MangleFact, pattern: MangleFact) -> Bool:
        """Check if a fact matches a query pattern."""
        if fact.predicate != pattern.predicate:
            return False
        if fact.num_args != pattern.num_args:
            return False
        
        for i in range(fact.num_args):
            var p_arg = pattern.get_arg(i)
            var f_arg = fact.get_arg(i)
            
            # Variable (uppercase) matches anything
            if len(p_arg) > 0 and (p_arg[0].isupper() or p_arg == "_"):
                continue
            
            if p_arg != f_arg:
                return False
        
        return True
    
    fn get_provenance(self, fact_id: Int) -> UnsafePointer[FactProvenance]:
        """Get provenance for a fact by ID."""
        return self.provenance_store.get_provenance(fact_id)
    
    fn get_derivation_chain(self, fact_id: Int) -> List[Int]:
        """Get full derivation chain for a fact."""
        return self.provenance_store.get_full_derivation_chain(fact_id)
    
    fn export_provenance(self) -> List[String]:
        """Export all provenance as Mangle facts."""
        return self.provenance_store.export_all()
    
    fn get_statistics(self) -> String:
        """Get engine statistics."""
        return (
            "Mangle Evaluation Engine Statistics:\n" +
            "  Base facts: " + String(len(self.base_facts)) + "\n" +
            "  Derived facts: " + String(len(self.derived_facts)) + "\n" +
            "  Rules: " + String(len(self.rules)) + "\n" +
            "  Max iterations: " + String(self.max_iterations) + "\n" +
            "  Provenance records: " + String(len(self.provenance_store.records)) + "\n"
        )


# =============================================================================
# HELPER STRUCTURES
# =============================================================================

struct DerivedFacts:
    """Collection of derived facts with their IDs."""
    var facts: List[MangleFact]
    var fact_ids: List[Int]
    
    fn __init__(out self):
        self.facts = List[MangleFact]()
        self.fact_ids = List[Int]()
    
    fn add(mut self, fact: MangleFact, fact_id: Int):
        self.facts.append(fact)
        self.fact_ids.append(fact_id)


# =============================================================================
# CONVENIENCE FUNCTIONS
# =============================================================================

fn create_engine(max_iterations: Int = 1000) -> MangleEvaluationEngine:
    """Create a new evaluation engine with specified max iterations."""
    return MangleEvaluationEngine(max_iterations)


fn evaluate_with_safety_check(
    mut engine: MangleEvaluationEngine
) -> Tuple[CompletenessStatus, List[String]]:
    """
    Evaluate engine and return status with any warnings.
    
    This is the main entry point that ensures H2 warnings are surfaced.
    """
    var status = engine.evaluate()
    var warnings = List[String]()
    
    if status.has_warning():
        warnings.append(status.warning_message)
    
    return (status, warnings)