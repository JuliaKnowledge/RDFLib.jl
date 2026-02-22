# ─── RDFS/OWL Forward-Chaining Inference ────────────────────────────

"""
    rdfs_closure!(g::RDFGraph)

Apply RDFS entailment rules to `g` in-place using fixed-point iteration.
Rules: rdfs2 (subclass typing), rdfs3 (subproperty), rdfs5 (subClassOf transitivity),
rdfs7 (subPropertyOf transitivity), rdfs9 (domain), rdfs10 (range).
"""
function rdfs_closure!(g::RDFGraph)
    _fixed_point!(g, _apply_rdfs_rules!)
end

"""
    rdfs_closure(g::RDFGraph) -> RDFGraph

Return a new graph containing all triples from `g` plus RDFS-entailed triples.
"""
function rdfs_closure(g::RDFGraph)
    result = _copy_graph(g)
    rdfs_closure!(result)
    result
end

"""
    owl_closure!(g::RDFGraph)

Apply RDFS + OWL entailment rules to `g` in-place using fixed-point iteration.
"""
function owl_closure!(g::RDFGraph)
    _fixed_point!(g, _apply_owl_rules!)
end

"""
    owl_closure(g::RDFGraph) -> RDFGraph

Return a new graph containing all triples from `g` plus RDFS+OWL-entailed triples.
"""
function owl_closure(g::RDFGraph)
    result = _copy_graph(g)
    owl_closure!(result)
    result
end

"""
    infer(g::RDFGraph; rules=:rdfs) -> RDFGraph

Return a new graph with inferred triples. `rules` can be `:rdfs`, `:owl`, or `:all`.
`:owl` and `:all` both apply RDFS + OWL rules.
"""
function infer(g::RDFGraph; rules::Symbol=:rdfs)
    if rules === :rdfs
        return rdfs_closure(g)
    elseif rules === :owl || rules === :all
        return owl_closure(g)
    else
        throw(ArgumentError("Unknown rule set: $rules. Use :rdfs, :owl, or :all"))
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
    collect(triples(g, pattern))
end

# ─── RDFS Rules ─────────────────────────────────────────────────────

function _apply_rdfs_rules!(g::RDFGraph)
    new_triples = Triple[]
    _rdfs5!(g, new_triples)   # subClassOf transitivity
    _rdfs7!(g, new_triples)   # subPropertyOf transitivity
    _rdfs2!(g, new_triples)   # subclass typing
    _rdfs3!(g, new_triples)   # subproperty
    _rdfs9!(g, new_triples)   # domain
    _rdfs10!(g, new_triples)  # range
    # Deduplicate against existing graph
    filter!(t -> !(t in g), new_triples)
    unique!(new_triples)
end

# rdfs5: rdfs:subClassOf is transitive
# If ?A rdfs:subClassOf ?B and ?B rdfs:subClassOf ?C, then ?A rdfs:subClassOf ?C
function _rdfs5!(g::RDFGraph, new_triples::Vector{Triple})
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

# rdfs7: rdfs:subPropertyOf is transitive
# If ?p rdfs:subPropertyOf ?q and ?q rdfs:subPropertyOf ?r, then ?p rdfs:subPropertyOf ?r
function _rdfs7!(g::RDFGraph, new_triples::Vector{Triple})
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

# rdfs2: If ?x rdf:type ?C and ?C rdfs:subClassOf ?D, then ?x rdf:type ?D
function _rdfs2!(g::RDFGraph, new_triples::Vector{Triple})
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

# rdfs3: If ?x ?p ?y and ?p rdfs:subPropertyOf ?q, then ?x ?q ?y
function _rdfs3!(g::RDFGraph, new_triples::Vector{Triple})
    sub_prop = RDFS.subPropertyOf
    for sp in _collect_triples(g, (nothing, sub_prop, nothing))
        p = sp.subject
        q = sp.object
        p isa URIRef || continue
        q isa URIRef || continue
        for t in _collect_triples(g, (nothing, p, nothing))
            push!(new_triples, Triple(t.subject, q, t.object))
        end
    end
end

# rdfs9: If ?p rdfs:domain ?C and ?x ?p ?y, then ?x rdf:type ?C
function _rdfs9!(g::RDFGraph, new_triples::Vector{Triple})
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

# rdfs10: If ?p rdfs:range ?C and ?x ?p ?y, then ?y rdf:type ?C
function _rdfs10!(g::RDFGraph, new_triples::Vector{Triple})
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

# ─── OWL Rules (includes RDFS) ─────────────────────────────────────

function _apply_owl_rules!(g::RDFGraph)
    new_triples = Triple[]
    # RDFS rules first
    _rdfs5!(g, new_triples)
    _rdfs7!(g, new_triples)
    _rdfs2!(g, new_triples)
    _rdfs3!(g, new_triples)
    _rdfs9!(g, new_triples)
    _rdfs10!(g, new_triples)
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
