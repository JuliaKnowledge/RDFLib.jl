# Reasoning

Inference and reasoning engines.

## RDFS/OWL Inference

```@docs
rdfs_closure
rdfs_closure!
owl_closure
owl_closure!
owl2_rl_closure
owl2_rl_closure!
infer
entails
```

## InfixOWL

```@docs
OWLClass
OWLObjectProperty
OWLDatatypeProperty
subclass_of!
owl_restriction
owl_ontology!
owl_individual
owl_union
owl_intersection
owl_complement
```

## N3 Reasoning

```@docs
Formula
serialize_n3
parse_n3
parse_n3!
RuleDirection
N3Rule
RuleSet
Binding
unify_triple
apply_bindings
is_ground
match_conjunction
N3Reasoner
reason
```

## N3 Builtins

```@docs
register_builtin!
is_builtin
evaluate_builtin
```

## N3 Proof

```@docs
StepType
ProofStep
extraction_step
inference_step
ProofTrace
record_extraction!
record_inference!
proof_to_n3
proof_to_graph
```

## Datalog

```@docs
DatalogProgram
DatalogRule
datalog_reason
semi_naive!
```

## ProbLog

```@docs
ProbLogProgram
PrologAtom
PrologClause
problog_query
problog_infer
parse_problog
```
