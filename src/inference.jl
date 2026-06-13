# ─── RDFS/OWL Forward-Chaining Inference ────────────────────────────

"""
    rdfs_closure!(g::RDFGraph; axiomatic=false)

Apply RDFS entailment rules to `g` in-place using fixed-point iteration.

Implemented rules (W3C RDF Semantics rule names):

- **rdfs2** — `?p rdfs:domain ?C . ?x ?p ?y` ⇒ `?x rdf:type ?C`
- **rdfs3** — `?p rdfs:range ?C . ?x ?p ?y` ⇒ `?y rdf:type ?C`
- **rdfs5** — `rdfs:subPropertyOf` transitivity
- **rdfs6** — `?p rdf:type rdf:Property` ⇒ `?p rdfs:subPropertyOf ?p`
- **rdfs7** — `?p rdfs:subPropertyOf ?q . ?x ?p ?y` ⇒ `?x ?q ?y`
- **rdfs9** — `?C rdfs:subClassOf ?D . ?x rdf:type ?C` ⇒ `?x rdf:type ?D`
- **rdfs10** — `?C rdf:type rdfs:Class` ⇒ `?C rdfs:subClassOf ?C`
- **rdfs11** — `rdfs:subClassOf` transitivity
- **rdfs12** — `?p rdf:type rdfs:ContainerMembershipProperty` ⇒
  `?p rdfs:subPropertyOf rdfs:member`
- **rdfs13** — `?d rdf:type rdfs:Datatype` ⇒ `?d rdfs:subClassOf rdfs:Literal`

Opt-in via `axiomatic=true` (off by default because they add an `rdf:type
rdfs:Resource` / `rdfs:subClassOf rdfs:Resource` triple for nearly every
node and significantly bloat the graph):

- **rdfs4a** — `?x ?p ?y` ⇒ `?x rdf:type rdfs:Resource`
- **rdfs4b** — `?x ?p ?y` ⇒ `?y rdf:type rdfs:Resource` (non-literal objects)
- **rdfs8** — `?C rdf:type rdfs:Class` ⇒ `?C rdfs:subClassOf rdfs:Resource`

Not implemented: **rdfs1** (every literal's datatype is an
`rdfs:Datatype` member). It concerns literal datatype membership — in this
triple-based implementation it would only assert `?dt rdf:type rdfs:Datatype`
for datatypes of literals appearing in the graph, which is essentially
vacuous for entailment purposes and is therefore skipped.
"""
function rdfs_closure!(g::RDFGraph; axiomatic::Bool=false)
    _fixed_point!(g, gg -> _apply_rdfs_rules!(gg; axiomatic=axiomatic))
end

"""
    rdfs_closure(g::RDFGraph; axiomatic=false) -> RDFGraph

Return a new graph containing all triples from `g` plus RDFS-entailed triples.
See [`rdfs_closure!`](@ref) for the rule list and the `axiomatic` keyword
(enables rdfs4a/4b/8, which derive `rdfs:Resource` membership for every node).
"""
function rdfs_closure(g::RDFGraph; axiomatic::Bool=false)
    result = _copy_graph(g)
    rdfs_closure!(result; axiomatic=axiomatic)
    result
end

"""
    owl_closure!(g::RDFGraph; axiomatic=false)

Apply RDFS + OWL entailment rules to `g` in-place using fixed-point iteration.
`axiomatic=true` additionally enables RDFS rules rdfs4a/4b/8 (see
[`rdfs_closure!`](@ref)).
"""
function owl_closure!(g::RDFGraph; axiomatic::Bool=false)
    _fixed_point!(g, gg -> _apply_owl_rules!(gg; axiomatic=axiomatic))
end

"""
    owl_closure(g::RDFGraph; axiomatic=false) -> RDFGraph

Return a new graph containing all triples from `g` plus RDFS+OWL-entailed triples.
"""
function owl_closure(g::RDFGraph; axiomatic::Bool=false)
    result = _copy_graph(g)
    owl_closure!(result; axiomatic=axiomatic)
    result
end

"""
    infer(g::RDFGraph; rules=:rdfs, axiomatic=false) -> RDFGraph

Return a new graph with inferred triples. `rules` can be `:rdfs`, `:owl`, `:owl2`, or `:all`.
`:owl` applies RDFS + OWL rules. `:owl2` applies RDFS + OWL + OWL 2 RL rules.
`:all` applies all available rules (OWL 2 RL).
`axiomatic=true` enables RDFS rules rdfs4a/4b/8 (everything is an
`rdfs:Resource`), which are off by default because they bloat the graph.
"""
function infer(g::RDFGraph; rules::Symbol=:rdfs, axiomatic::Bool=false)
    if rules === :rdfs
        return rdfs_closure(g; axiomatic=axiomatic)
    elseif rules === :owl
        return owl_closure(g; axiomatic=axiomatic)
    elseif rules === :owl2 || rules === :all
        return owl2_rl_closure(g; axiomatic=axiomatic)
    else
        throw(ArgumentError("Unknown rule set: $rules. Use :rdfs, :owl, :owl2, or :all"))
    end
end

"""
    entails(g::RDFGraph, triple::Triple) -> Bool

Check whether `triple` is entailed by `g` under OWL closure.
"""
function entails(g::RDFGraph, triple::Triple)
    triple in g && return true
    closed = owl_closure(g)
    triple in closed
end

# ─── Internal helpers ───────────────────────────────────────────────

function _copy_graph(g::RDFGraph)
    result = RDFGraph()
    for t in g
        add!(result, t)
    end
    result
end

function _fixed_point!(g::RDFGraph, apply_fn!)
    while true
        new_triples = apply_fn!(g)
        isempty(new_triples) && break
        for t in new_triples
            add!(g, t)
        end
    end
    g
end

function _collect_triples(g::RDFGraph, pattern::TriplePattern)
    triples(g, pattern)
end

# ─── RDFS Rules ─────────────────────────────────────────────────────
# Rule names follow the W3C RDF Semantics entailment rule numbering.
# rdfs1 (literal datatype membership) is intentionally not implemented:
# it would only assert `?dt rdf:type rdfs:Datatype` for datatypes of
# literals appearing in the graph, which is vacuous for entailment here.

function _apply_rdfs_rules!(g::RDFGraph; axiomatic::Bool=false)
    new_triples = Triple[]
    _push_rdfs_rules!(g, new_triples; axiomatic=axiomatic)
    # Deduplicate against existing graph
    filter!(t -> !(t in g), new_triples)
    unique!(new_triples)
end

# Push one round of RDFS-rule conclusions into `new_triples` (no dedup).
function _push_rdfs_rules!(g::RDFGraph, new_triples::Vector{Triple}; axiomatic::Bool=false)
    _rdfs11!(g, new_triples)  # subClassOf transitivity
    _rdfs5!(g, new_triples)   # subPropertyOf transitivity
    _rdfs9!(g, new_triples)   # subclass typing
    _rdfs7!(g, new_triples)   # subproperty usage
    _rdfs2!(g, new_triples)   # domain
    _rdfs3!(g, new_triples)   # range
    _rdfs6!(g, new_triples)   # property reflexivity
    _rdfs10!(g, new_triples)  # class reflexivity
    _rdfs12!(g, new_triples)  # ContainerMembershipProperty → rdfs:member
    _rdfs13!(g, new_triples)  # Datatype → subclass of rdfs:Literal
    if axiomatic
        _rdfs4!(g, new_triples)  # rdfs4a/4b: everything is an rdfs:Resource
        _rdfs8!(g, new_triples)  # classes are subclasses of rdfs:Resource
    end
    new_triples
end

# rdfs11: rdfs:subClassOf is transitive
# If ?A rdfs:subClassOf ?B and ?B rdfs:subClassOf ?C, then ?A rdfs:subClassOf ?C
function _rdfs11!(g::RDFGraph, new_triples::Vector{Triple})
    subclass_of = RDFS.subClassOf
    for t1 in _collect_triples(g, (nothing, subclass_of, nothing))
        a = t1.subject
        b = t1.object
        b isa Node || continue
        for t2 in _collect_triples(g, (b, subclass_of, nothing))
            c = t2.object
            c isa Node || continue
            a == c && continue
            push!(new_triples, Triple(a, subclass_of, c))
        end
    end
end

# rdfs5: rdfs:subPropertyOf is transitive
# If ?p rdfs:subPropertyOf ?q and ?q rdfs:subPropertyOf ?r, then ?p rdfs:subPropertyOf ?r
function _rdfs5!(g::RDFGraph, new_triples::Vector{Triple})
    sub_prop = RDFS.subPropertyOf
    for t1 in _collect_triples(g, (nothing, sub_prop, nothing))
        p = t1.subject
        q = t1.object
        q isa URIRef || continue
        for t2 in _collect_triples(g, (q, sub_prop, nothing))
            r = t2.object
            r isa Node || continue
            p == r && continue
            p isa URIRef || continue
            push!(new_triples, Triple(p, sub_prop, r))
        end
    end
end

# rdfs9: If ?x rdf:type ?C and ?C rdfs:subClassOf ?D, then ?x rdf:type ?D
function _rdfs9!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    subclass_of = RDFS.subClassOf
    for t in _collect_triples(g, (nothing, rdf_type, nothing))
        c = t.object
        c isa Node || continue
        for sc in _collect_triples(g, (c, subclass_of, nothing))
            d = sc.object
            push!(new_triples, Triple(t.subject, rdf_type, d))
        end
    end
end

# rdfs7: If ?x ?p ?y and ?p rdfs:subPropertyOf ?q, then ?x ?q ?y
function _rdfs7!(g::RDFGraph, new_triples::Vector{Triple})
    sub_prop = RDFS.subPropertyOf
    for sp in _collect_triples(g, (nothing, sub_prop, nothing))
        p = sp.subject
        q = sp.object
        p isa URIRef || continue
        q isa URIRef || continue
        p == q && continue
        for t in _collect_triples(g, (nothing, p, nothing))
            push!(new_triples, Triple(t.subject, q, t.object))
        end
    end
end

# rdfs2: If ?p rdfs:domain ?C and ?x ?p ?y, then ?x rdf:type ?C
function _rdfs2!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    rdfs_domain = RDFS.domain
    for d in _collect_triples(g, (nothing, rdfs_domain, nothing))
        p = d.subject
        c = d.object
        p isa URIRef || continue
        for t in _collect_triples(g, (nothing, p, nothing))
            push!(new_triples, Triple(t.subject, rdf_type, c))
        end
    end
end

# rdfs3: If ?p rdfs:range ?C and ?x ?p ?y, then ?y rdf:type ?C
function _rdfs3!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    rdfs_range = RDFS.range
    for r in _collect_triples(g, (nothing, rdfs_range, nothing))
        p = r.subject
        c = r.object
        p isa URIRef || continue
        for t in _collect_triples(g, (nothing, p, nothing))
            obj = t.object
            obj isa Node || continue
            push!(new_triples, Triple(obj, rdf_type, c))
        end
    end
end

# rdfs6: If ?p rdf:type rdf:Property, then ?p rdfs:subPropertyOf ?p
function _rdfs6!(g::RDFGraph, new_triples::Vector{Triple})
    sub_prop = RDFS.subPropertyOf
    for t in _collect_triples(g, (nothing, RDF.type, RDF.Property))
        p = t.subject
        p isa URIRef || continue
        push!(new_triples, Triple(p, sub_prop, p))
    end
end

# rdfs10: If ?C rdf:type rdfs:Class, then ?C rdfs:subClassOf ?C
function _rdfs10!(g::RDFGraph, new_triples::Vector{Triple})
    subclass_of = RDFS.subClassOf
    for t in _collect_triples(g, (nothing, RDF.type, RDFS.Class))
        c = t.subject
        c isa Node || continue
        push!(new_triples, Triple(c, subclass_of, c))
    end
end

# rdfs12: If ?p rdf:type rdfs:ContainerMembershipProperty,
# then ?p rdfs:subPropertyOf rdfs:member
function _rdfs12!(g::RDFGraph, new_triples::Vector{Triple})
    sub_prop = RDFS.subPropertyOf
    for t in _collect_triples(g, (nothing, RDF.type, RDFS.ContainerMembershipProperty))
        p = t.subject
        p isa URIRef || continue
        push!(new_triples, Triple(p, sub_prop, RDFS.member))
    end
end

# rdfs13: If ?d rdf:type rdfs:Datatype, then ?d rdfs:subClassOf rdfs:Literal
function _rdfs13!(g::RDFGraph, new_triples::Vector{Triple})
    subclass_of = RDFS.subClassOf
    for t in _collect_triples(g, (nothing, RDF.type, RDFS.Datatype))
        d = t.subject
        d isa Node || continue
        push!(new_triples, Triple(d, subclass_of, RDFS.Literal))
    end
end

# rdfs4a/4b (axiomatic, opt-in): If ?x ?p ?y, then ?x rdf:type rdfs:Resource
# and ?y rdf:type rdfs:Resource (literal objects are skipped — a literal
# cannot be the subject of an RDF triple).
function _rdfs4!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    resource = RDFS.Resource
    for t in g
        push!(new_triples, Triple(t.subject, rdf_type, resource))      # rdfs4a
        if t.object isa Node
            push!(new_triples, Triple(t.object, rdf_type, resource))   # rdfs4b
        end
    end
end

# rdfs8 (axiomatic, opt-in): If ?C rdf:type rdfs:Class,
# then ?C rdfs:subClassOf rdfs:Resource
function _rdfs8!(g::RDFGraph, new_triples::Vector{Triple})
    subclass_of = RDFS.subClassOf
    for t in _collect_triples(g, (nothing, RDF.type, RDFS.Class))
        c = t.subject
        c isa Node || continue
        push!(new_triples, Triple(c, subclass_of, RDFS.Resource))
    end
end

# ─── OWL Rules (includes RDFS) ─────────────────────────────────────

function _apply_owl_rules!(g::RDFGraph; axiomatic::Bool=false)
    new_triples = Triple[]
    # RDFS rules first
    _push_rdfs_rules!(g, new_triples; axiomatic=axiomatic)
    # OWL rules
    _owl_equivalent_class!(g, new_triples)
    _owl_equivalent_property!(g, new_triples)
    _owl_transitive_property!(g, new_triples)
    _owl_symmetric_property!(g, new_triples)
    _owl_inverse_of!(g, new_triples)
    _owl_same_as!(g, new_triples)
    # Deduplicate against existing graph
    filter!(t -> !(t in g), new_triples)
    unique!(new_triples)
end

# owl:equivalentClass ↔ mutual rdfs:subClassOf
function _owl_equivalent_class!(g::RDFGraph, new_triples::Vector{Triple})
    eq_class = OWL.equivalentClass
    subclass_of = RDFS.subClassOf
    for t in _collect_triples(g, (nothing, eq_class, nothing))
        a, b = t.subject, t.object
        b isa Node || continue
        push!(new_triples, Triple(a, subclass_of, b))
        push!(new_triples, Triple(b, subclass_of, a))
    end
end

# owl:equivalentProperty ↔ mutual rdfs:subPropertyOf
function _owl_equivalent_property!(g::RDFGraph, new_triples::Vector{Triple})
    eq_prop = OWL.equivalentProperty
    sub_prop = RDFS.subPropertyOf
    for t in _collect_triples(g, (nothing, eq_prop, nothing))
        p, q = t.subject, t.object
        p isa URIRef || continue
        q isa URIRef || continue
        push!(new_triples, Triple(p, sub_prop, q))
        push!(new_triples, Triple(q, sub_prop, p))
    end
end

# owl:TransitiveProperty — if ?p a owl:TransitiveProperty, ?x ?p ?y, ?y ?p ?z → ?x ?p ?z
function _owl_transitive_property!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    trans_prop = OWL.TransitiveProperty
    for tp in _collect_triples(g, (nothing, rdf_type, trans_prop))
        p = tp.subject
        p isa URIRef || continue
        for t1 in _collect_triples(g, (nothing, p, nothing))
            y = t1.object
            y isa Node || continue
            for t2 in _collect_triples(g, (y, p, nothing))
                t1.subject == t2.object && continue
                push!(new_triples, Triple(t1.subject, p, t2.object))
            end
        end
    end
end

# owl:SymmetricProperty — if ?p a owl:SymmetricProperty, ?x ?p ?y → ?y ?p ?x
function _owl_symmetric_property!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    sym_prop = OWL.SymmetricProperty
    for sp in _collect_triples(g, (nothing, rdf_type, sym_prop))
        p = sp.subject
        p isa URIRef || continue
        for t in _collect_triples(g, (nothing, p, nothing))
            obj = t.object
            obj isa Node || continue
            push!(new_triples, Triple(obj, p, t.subject))
        end
    end
end

# owl:inverseOf — if ?p owl:inverseOf ?q, ?x ?p ?y → ?y ?q ?x (and vice versa)
function _owl_inverse_of!(g::RDFGraph, new_triples::Vector{Triple})
    inverse_of = OWL.inverseOf
    for inv in _collect_triples(g, (nothing, inverse_of, nothing))
        p, q = inv.subject, inv.object
        p isa URIRef || continue
        q isa URIRef || continue
        for t in _collect_triples(g, (nothing, p, nothing))
            t.object isa Node || continue
            push!(new_triples, Triple(t.object, q, t.subject))
        end
        for t in _collect_triples(g, (nothing, q, nothing))
            t.object isa Node || continue
            push!(new_triples, Triple(t.object, p, t.subject))
        end
    end
end

# owl:sameAs — transitive, symmetric; propagate properties
function _owl_same_as!(g::RDFGraph, new_triples::Vector{Triple})
    same_as = OWL.sameAs
    # Symmetry
    for t in _collect_triples(g, (nothing, same_as, nothing))
        t.object isa Node || continue
        push!(new_triples, Triple(t.object, same_as, t.subject))
    end
    # Transitivity
    for t1 in _collect_triples(g, (nothing, same_as, nothing))
        b = t1.object
        b isa Node || continue
        for t2 in _collect_triples(g, (b, same_as, nothing))
            t1.subject == t2.object && continue
            push!(new_triples, Triple(t1.subject, same_as, t2.object))
        end
    end
    # Property propagation: if ?x owl:sameAs ?y, copy all (?x ?p ?o) → (?y ?p ?o)
    # and (?s ?p ?x) → (?s ?p ?y)
    for sa in _collect_triples(g, (nothing, same_as, nothing))
        x, y = sa.subject, sa.object
        y isa Node || continue
        for t in _collect_triples(g, (x, nothing, nothing))
            t.predicate == same_as && continue
            push!(new_triples, Triple(y, t.predicate, t.object))
        end
        for t in _collect_triples(g, (nothing, nothing, x))
            t.predicate == same_as && continue
            t.object isa Node || continue
            push!(new_triples, Triple(t.subject, t.predicate, y))
        end
    end
end

# ─── OWL 2 RL Rules ────────────────────────────────────────────────

function _owl2_collect_list(g::RDFGraph, head::Node)
    rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    rdf_rest  = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    rdf_nil   = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    result = Identifier[]
    head == rdf_nil && return result
    current = head
    while true
        firsts = collect(objects(g, current, rdf_first))
        isempty(firsts) && break
        push!(result, firsts[1])
        rests = collect(objects(g, current, rdf_rest))
        isempty(rests) && break
        next = rests[1]
        next == rdf_nil && break
        next isa Node || break
        current = next
    end
    result
end

function _owl2_rule_property_chain!(g::RDFGraph, new_triples::Vector{Triple})
    prop_chain = OWL.propertyChainAxiom
    for t in _collect_triples(g, (nothing, prop_chain, nothing))
        p = t.subject
        p isa URIRef || continue
        list_head = t.object
        list_head isa Node || continue
        chain = _owl2_collect_list(g, list_head)
        length(chain) < 2 && continue
        all(c -> c isa URIRef, chain) || continue
        chain_uris = URIRef[c::URIRef for c in chain]
        if length(chain_uris) == 2
            p1, p2 = chain_uris
            for t1 in _collect_triples(g, (nothing, p1, nothing))
                b = t1.object
                b isa Node || continue
                for t2 in _collect_triples(g, (b, p2, nothing))
                    push!(new_triples, Triple(t1.subject, p, t2.object))
                end
            end
        else
            for start_t in _collect_triples(g, (nothing, chain_uris[1], nothing))
                _walk_chain(g, start_t.subject, chain_uris, 2, p, new_triples, start_t.object)
            end
        end
    end
end

function _walk_chain(g::RDFGraph, start::Node, chain::Vector{URIRef}, idx::Int,
                     target_pred::URIRef, new_triples::Vector{Triple}, current::Identifier)
    current isa Node || return
    if idx > length(chain)
        push!(new_triples, Triple(start, target_pred, current))
        return
    end
    for t in _collect_triples(g, (current, chain[idx], nothing))
        _walk_chain(g, start, chain, idx + 1, target_pred, new_triples, t.object)
    end
end

function _owl2_rule_has_value!(g::RDFGraph, new_triples::Vector{Triple})
    has_value = OWL.hasValue
    on_prop = OWL.onProperty
    rdf_type = RDF.type
    for hv in _collect_triples(g, (nothing, has_value, nothing))
        c = hv.subject
        v = hv.object
        c isa Node || continue
        props = collect(objects(g, c, on_prop))
        for prop in props
            prop isa URIRef || continue
            for inst in _collect_triples(g, (nothing, rdf_type, c))
                push!(new_triples, Triple(inst.subject, prop, v))
            end
            for inst in _collect_triples(g, (nothing, prop, v))
                push!(new_triples, Triple(inst.subject, rdf_type, c))
            end
        end
    end
end

function _owl2_rule_some_values_from!(g::RDFGraph, new_triples::Vector{Triple})
    some_from = OWL.someValuesFrom
    on_prop = OWL.onProperty
    rdf_type = RDF.type
    for sv in _collect_triples(g, (nothing, some_from, nothing))
        c = sv.subject
        d = sv.object
        c isa Node || continue
        props = collect(objects(g, c, on_prop))
        for prop in props
            prop isa URIRef || continue
            for pt in _collect_triples(g, (nothing, prop, nothing))
                y = pt.object
                y isa Node || continue
                for _ in _collect_triples(g, (y, rdf_type, d))
                    push!(new_triples, Triple(pt.subject, rdf_type, c))
                    break
                end
            end
        end
    end
end

function _owl2_rule_all_values_from!(g::RDFGraph, new_triples::Vector{Triple})
    all_from = OWL.allValuesFrom
    on_prop = OWL.onProperty
    rdf_type = RDF.type
    for av in _collect_triples(g, (nothing, all_from, nothing))
        c = av.subject
        d = av.object
        c isa Node || continue
        props = collect(objects(g, c, on_prop))
        for prop in props
            prop isa URIRef || continue
            for inst in _collect_triples(g, (nothing, rdf_type, c))
                x = inst.subject
                for pt in _collect_triples(g, (x, prop, nothing))
                    y = pt.object
                    y isa Node || continue
                    push!(new_triples, Triple(y, rdf_type, d))
                end
            end
        end
    end
end

function _owl2_rule_complement_of!(g::RDFGraph, new_triples::Vector{Triple})
    complement = OWL.complementOf
    rdf_type = RDF.type
    for co in _collect_triples(g, (nothing, complement, nothing))
        c = co.subject
        d = co.object
        c isa Node || continue
        d isa Node || continue
        for inst in _collect_triples(g, (nothing, rdf_type, c))
            x = inst.subject
            for _ in _collect_triples(g, (x, rdf_type, d))
                @warn "OWL2 RL: Inconsistency — $(x) is type of both $(c) and complement $(d)"
                break
            end
        end
    end
end

function _owl2_rule_disjoint_with!(g::RDFGraph, new_triples::Vector{Triple})
    disjoint = OWL.disjointWith
    rdf_type = RDF.type
    for dw in _collect_triples(g, (nothing, disjoint, nothing))
        c = dw.subject
        d = dw.object
        c isa Node || continue
        d isa Node || continue
        for inst in _collect_triples(g, (nothing, rdf_type, c))
            x = inst.subject
            for _ in _collect_triples(g, (x, rdf_type, d))
                @warn "OWL2 RL: Inconsistency — $(x) is type of disjoint classes $(c) and $(d)"
                break
            end
        end
    end
end

function _owl2_rule_different_from!(g::RDFGraph, new_triples::Vector{Triple})
    diff_from = OWL.differentFrom
    for t in _collect_triples(g, (nothing, diff_from, nothing))
        t.object isa Node || continue
        push!(new_triples, Triple(t.object, diff_from, t.subject))
    end
end

function _owl2_rule_intersection_of!(g::RDFGraph, new_triples::Vector{Triple})
    intersection = OWL.intersectionOf
    rdf_type = RDF.type
    for io in _collect_triples(g, (nothing, intersection, nothing))
        c = io.subject
        list_head = io.object
        c isa Node || continue
        list_head isa Node || continue
        classes = _owl2_collect_list(g, list_head)
        isempty(classes) && continue
        first_class = classes[1]
        first_class isa Node || continue
        for inst in _collect_triples(g, (nothing, rdf_type, first_class))
            x = inst.subject
            all_match = true
            for ci in 2:length(classes)
                cls = classes[ci]
                cls isa Node || (all_match = false; break)
                found = false
                for _ in _collect_triples(g, (x, rdf_type, cls))
                    found = true
                    break
                end
                if !found
                    all_match = false
                    break
                end
            end
            all_match && push!(new_triples, Triple(x, rdf_type, c))
        end
    end
end

function _owl2_rule_union_of!(g::RDFGraph, new_triples::Vector{Triple})
    union_of = OWL.unionOf
    rdf_type = RDF.type
    for uo in _collect_triples(g, (nothing, union_of, nothing))
        c = uo.subject
        list_head = uo.object
        c isa Node || continue
        list_head isa Node || continue
        classes = _owl2_collect_list(g, list_head)
        for cls in classes
            cls isa Node || continue
            for inst in _collect_triples(g, (nothing, rdf_type, cls))
                push!(new_triples, Triple(inst.subject, rdf_type, c))
            end
        end
    end
end

function _owl2_rule_has_key!(g::RDFGraph, new_triples::Vector{Triple})
    has_key = OWL.hasKey
    rdf_type = RDF.type
    same_as = OWL.sameAs
    for hk in _collect_triples(g, (nothing, has_key, nothing))
        c = hk.subject
        list_head = hk.object
        c isa Node || continue
        list_head isa Node || continue
        key_props = _owl2_collect_list(g, list_head)
        isempty(key_props) && continue
        all(kp -> kp isa URIRef, key_props) || continue
        key_uris = URIRef[kp::URIRef for kp in key_props]
        instances = Node[]
        for inst in _collect_triples(g, (nothing, rdf_type, c))
            inst.subject isa Node && push!(instances, inst.subject)
        end
        for i in 1:length(instances)
            for j in (i+1):length(instances)
                x, y = instances[i], instances[j]
                x == y && continue
                all_keys_match = true
                for kp in key_uris
                    x_vals = Set(obj for obj in objects(g, x, kp))
                    y_vals = Set(obj for obj in objects(g, y, kp))
                    if isempty(x_vals) || isempty(y_vals) || isempty(intersect(x_vals, y_vals))
                        all_keys_match = false
                        break
                    end
                end
                if all_keys_match
                    push!(new_triples, Triple(x, same_as, y))
                    push!(new_triples, Triple(y, same_as, x))
                end
            end
        end
    end
end

function _owl2_rule_functional_property!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    func_prop = OWL.FunctionalProperty
    same_as = OWL.sameAs
    for fp in _collect_triples(g, (nothing, rdf_type, func_prop))
        p = fp.subject
        p isa URIRef || continue
        by_subject = Dict{Node, Vector{Identifier}}()
        for t in _collect_triples(g, (nothing, p, nothing))
            subj = t.subject
            subj isa Node || continue
            vals = get!(by_subject, subj, Identifier[])
            push!(vals, t.object)
        end
        for (_, vals) in by_subject
            length(vals) < 2 && continue
            for i in 1:length(vals)
                for j in (i+1):length(vals)
                    y1, y2 = vals[i], vals[j]
                    y1 == y2 && continue
                    y1 isa Node || continue
                    y2 isa Node || continue
                    push!(new_triples, Triple(y1, same_as, y2))
                    push!(new_triples, Triple(y2, same_as, y1))
                end
            end
        end
    end
end

function _owl2_rule_inverse_functional_property!(g::RDFGraph, new_triples::Vector{Triple})
    rdf_type = RDF.type
    inv_func = OWL.InverseFunctionalProperty
    same_as = OWL.sameAs
    for ifp in _collect_triples(g, (nothing, rdf_type, inv_func))
        p = ifp.subject
        p isa URIRef || continue
        by_object = Dict{Identifier, Vector{Node}}()
        for t in _collect_triples(g, (nothing, p, nothing))
            subj = t.subject
            subj isa Node || continue
            subjs = get!(by_object, t.object, Node[])
            push!(subjs, subj)
        end
        for (_, subjs) in by_object
            length(subjs) < 2 && continue
            for i in 1:length(subjs)
                for j in (i+1):length(subjs)
                    x1, x2 = subjs[i], subjs[j]
                    x1 == x2 && continue
                    push!(new_triples, Triple(x1, same_as, x2))
                    push!(new_triples, Triple(x2, same_as, x1))
                end
            end
        end
    end
end

function _apply_owl2_rl_rules!(g::RDFGraph; axiomatic::Bool=false)
    new_triples = Triple[]
    _push_rdfs_rules!(g, new_triples; axiomatic=axiomatic)
    _owl_equivalent_class!(g, new_triples)
    _owl_equivalent_property!(g, new_triples)
    _owl_transitive_property!(g, new_triples)
    _owl_symmetric_property!(g, new_triples)
    _owl_inverse_of!(g, new_triples)
    _owl_same_as!(g, new_triples)
    _owl2_rule_property_chain!(g, new_triples)
    _owl2_rule_has_value!(g, new_triples)
    _owl2_rule_some_values_from!(g, new_triples)
    _owl2_rule_all_values_from!(g, new_triples)
    _owl2_rule_complement_of!(g, new_triples)
    _owl2_rule_disjoint_with!(g, new_triples)
    _owl2_rule_different_from!(g, new_triples)
    _owl2_rule_intersection_of!(g, new_triples)
    _owl2_rule_union_of!(g, new_triples)
    _owl2_rule_has_key!(g, new_triples)
    _owl2_rule_functional_property!(g, new_triples)
    _owl2_rule_inverse_functional_property!(g, new_triples)
    filter!(t -> !(t in g), new_triples)
    unique!(new_triples)
end

"""
    owl2_rl_closure!(g::RDFGraph; axiomatic=false)

Apply OWL 2 RL profile rules to `g` in-place using fixed-point iteration.
`axiomatic=true` additionally enables RDFS rules rdfs4a/4b/8 (see
[`rdfs_closure!`](@ref)).
"""
function owl2_rl_closure!(g::RDFGraph; axiomatic::Bool=false)
    _fixed_point!(g, gg -> _apply_owl2_rl_rules!(gg; axiomatic=axiomatic))
end

"""
    owl2_rl_closure(g::RDFGraph; axiomatic=false) -> RDFGraph

Return a new graph containing all triples from `g` plus OWL 2 RL-entailed triples.
"""
function owl2_rl_closure(g::RDFGraph; axiomatic::Bool=false)
    result = _copy_graph(g)
    owl2_rl_closure!(result; axiomatic=axiomatic)
    result
end
