# ─── OWL class-expression query answering (query rewriting) ─────────
#
# SPARQL entailment-regime tests (sparql11/entailment) pose queries whose WHERE
# clause contains ANONYMOUS OWL class expressions — bnode-rooted
# owl:intersectionOf / owl:unionOf / owl:oneOf / owl:Restriction structures —
# and ask for their instances, e.g.
#
#     SELECT ?x WHERE { ?x a [ owl:intersectionOf ( :A :B ) ] }
#
# The class isn't named in the data, so it must be interpreted. We answer such
# queries by REWRITING the anonymous class-expression sub-pattern into an
# equivalent Basic Graph Pattern (plus UNION / VALUES) over the materialized
# (RL/RDFS-closed) data, then evaluating the rewritten query with `sparql_query`.
#
# Rewrites (over EXISTING individuals; no anonymous-individual / DL existential
# generation — that is out of scope and documented):
#
#   ?x a [owl:intersectionOf (C1..Cn)]            -> ?x a C1 . … . ?x a Cn
#   ?x a [owl:unionOf (C1..Cn)]                   -> { ?x a C1 } UNION … UNION { ?x a Cn }
#   ?x a [owl:oneOf (i1..in)]                     -> VALUES ?x { i1 … in }
#   ?x a [Restriction onProperty p hasValue v]    -> ?x p v
#   ?x a [Restriction onProperty p someValuesFrom C] -> ?x p ?fresh . ?fresh a C
#   ?x a [Restriction onProperty p allValuesFrom C]  -> ?x p ?f . FILTER NOT EXISTS{?x p ?g. MINUS{?g a C}}
#   ?x a [owl:complementOf C]                     -> best effort (domain MINUS class)
#   nested class expressions recurse.
#
# This file also provides `materialize_entailment!`, the regime-aware closure the
# harness materializes before querying: it runs the RL or RDFS closure and adds
# the entailment-regime completions the W3C answers rely on (reflexive
# subClassOf/subPropertyOf over owl/rdfs classes & properties, the RDF rdfD2
# predicate→rdf:Property axiom, owl meta-class subsumptions, reflexive sameAs).

const _OWL = "http://www.w3.org/2002/07/owl#"
const _RDFS_NS = "http://www.w3.org/2000/01/rdf-schema#"
const _RDF_NS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

# ─── regime-aware materialization ───────────────────────────────────

"""
    materialize_entailment!(g::RDFGraph, regimes) -> RDFGraph

Materialize the entailment closure on `g` for the strongest of the requested
`regimes` (a vector of short regime names such as "OWL-Direct", "RDFS", "RDF",
"D"), then add the regime completions that the W3C SPARQL-entailment answers
depend on. Modifies `g` in place.
"""
function materialize_entailment!(g::RDFGraph, regimes)
    isempty(regimes) && return g
    owlish = any(r -> startswith(r, "OWL"), regimes)
    if owlish
        owl2_rl_closure!(g)
    elseif any(r -> r in ("RDFS", "RDF", "D"), regimes)
        rdfs_closure!(g)
    else
        return g
    end
    _regime_completions!(g; owl = owlish)
    # A second closure pass propagates the newly-added meta-axioms (e.g. reflexive
    # subClassOf feeding rdfs9, owl:ObjectProperty→rdf:Property feeding rdfs6/rdfD2).
    owlish ? owl2_rl_closure!(g) : rdfs_closure!(g)
    _regime_completions!(g; owl = owlish)
    g
end

# Add entailment-regime axioms the bare RDFS/RL closures do not derive.
function _regime_completions!(g::RDFGraph; owl::Bool)
    rdf_type   = URIRef(_RDF_NS * "type")
    rdfProperty = URIRef(_RDF_NS * "Property")
    subClassOf  = URIRef(_RDFS_NS * "subClassOf")
    subPropOf   = URIRef(_RDFS_NS * "subPropertyOf")
    rdfsClass   = URIRef(_RDFS_NS * "Class")
    sameAs      = URIRef(_OWL * "sameAs")
    owlClass    = URIRef(_OWL * "Class")
    owlObjProp  = URIRef(_OWL * "ObjectProperty")
    owlDataProp = URIRef(_OWL * "DatatypeProperty")
    owlAnnProp  = URIRef(_OWL * "AnnotationProperty")
    owlNamedInd = URIRef(_OWL * "NamedIndividual")

    add = Triple[]

    # Treat owl:Class / rdfs:Class subjects as classes; owl:*Property as
    # rdf:Property. This makes reflexive subClassOf/subPropertyOf fire and lets
    # owl:ObjectProperty count as rdf:Property (rdf01).
    classes  = Set{Node}()
    props    = Set{URIRef}()
    owlRestriction = URIRef(_OWL * "Restriction")
    for t in triples(g, (nothing, rdf_type, owlClass));      t.subject isa Node && push!(classes, t.subject); end
    for t in triples(g, (nothing, rdf_type, rdfsClass));     t.subject isa Node && push!(classes, t.subject); end
    for t in triples(g, (nothing, rdf_type, owlRestriction)); t.subject isa Node && push!(classes, t.subject); end
    for cls in (owlObjProp, owlDataProp, owlAnnProp)
        for t in triples(g, (nothing, rdf_type, cls)); t.subject isa URIRef && push!(props, t.subject); end
    end
    for t in triples(g, (nothing, rdf_type, rdfProperty)); t.subject isa URIRef && push!(props, t.subject); end

    for c in classes
        push!(add, Triple(c, subClassOf, c))            # reflexive subClassOf
    end
    # owl:Nothing is a subclass of every class (the bottom class). The W3C
    # subClassOf answers list owl:Nothing among the subclasses of a queried class.
    if owl
        owlNothing = URIRef(_OWL * "Nothing")
        for c in classes
            c == owlNothing && continue
            push!(add, Triple(owlNothing, subClassOf, c))
        end
    end
    for p in props
        push!(add, Triple(p, subPropOf, p))             # reflexive subPropertyOf
        push!(add, Triple(p, rdf_type, rdfProperty))    # owl:*Property ⊑ rdf:Property
    end

    # RDF rule rdfD2: every predicate of a triple is an rdf:Property.
    for t in g
        t.predicate isa URIRef && push!(add, Triple(t.predicate, rdf_type, rdfProperty))
    end

    if owl
        rdfsDomain = URIRef(_RDFS_NS * "domain")
        rdfsRange  = URIRef(_RDFS_NS * "range")
        owlThing   = URIRef(_OWL * "Thing")
        owlInverse = URIRef(_OWL * "inverseOf")
        objProps = Set{URIRef}()
        for t in triples(g, (nothing, rdf_type, owlObjProp)); t.subject isa URIRef && push!(objProps, t.subject); end
        # In OWL every object property has domain and range owl:Thing; datatype
        # properties have domain owl:Thing. This is what sparqldl domain/range
        # tests expect alongside the user-declared domain/range.
        for p in objProps
            push!(add, Triple(p, rdfsDomain, owlThing))
            push!(add, Triple(p, rdfsRange,  owlThing))
        end
        for t in triples(g, (nothing, rdf_type, owlDataProp))
            t.subject isa URIRef && push!(add, Triple(t.subject, rdfsDomain, owlThing))
        end
        # owl:inverseOf swaps domain and range: p inverseOf q ⊢ domain(p)=range(q),
        # range(p)=domain(q).
        for t in triples(g, (nothing, owlInverse, nothing))
            p = t.subject; q = t.object
            (p isa URIRef && q isa URIRef) || continue
            for dt in triples(g, (p, rdfsDomain, nothing)); push!(add, Triple(q, rdfsRange,  dt.object)); end
            for rt in triples(g, (p, rdfsRange,  nothing)); push!(add, Triple(q, rdfsDomain, rt.object)); end
            for dt in triples(g, (q, rdfsDomain, nothing)); push!(add, Triple(p, rdfsRange,  dt.object)); end
            for rt in triples(g, (q, rdfsRange,  nothing)); push!(add, Triple(p, rdfsDomain, rt.object)); end
        end

        # Reflexive + symmetric owl:sameAs. Reflexive identity holds for every named
        # individual (owl:NamedIndividual) so join queries that walk sameAs chains
        # see the trivial identities even when no sameAs is asserted.
        inds = Set{Node}()
        for t in triples(g, (nothing, rdf_type, owlNamedInd)); t.subject isa Node && push!(inds, t.subject); end
        for t in triples(g, (nothing, sameAs, nothing))
            t.subject isa Node && push!(inds, t.subject)
            t.object  isa Node && push!(inds, t.object)
            t.object  isa Node && push!(add, Triple(t.object, sameAs, t.subject))   # symmetric
        end
        for i in inds
            push!(add, Triple(i, sameAs, i))            # reflexive sameAs
        end
    end

    for t in add
        t in g || add!(g, t)
    end
    g
end

# ─── class-expression query rewriting ───────────────────────────────

# A fresh-variable counter shared across one rewrite, plus the (optionally
# supplied, already entailment-closed) data graph and the query's prefix map so
# the rewriter can resolve class-expression terms to graph nodes and perform
# structural class matching / closed-role cardinality counting.
mutable struct _RWState
    n::Int
    union_emitted::Bool
    g::Union{Nothing,RDFGraph}
    prefixes::Dict{String,String}
end
_RWState(n::Int) = _RWState(n, false, nothing, Dict{String,String}())
_RWState(n::Int, g, prefixes) = _RWState(n, false, g, prefixes)
_fresh(st::_RWState) = (st.n += 1; "?__owlx$(st.n)")

# Recursive-descent parse of the class-expression text starting at `i` in `s`,
# which must point at an opening '['. Returns (node::Dict, next_index_after_']').
# The node maps predicate-localname => parsed value (term string, list of terms,
# or nested node Dict).
function _parse_bracket(s::AbstractString, i::Int)
    @assert s[i] == '['
    i = nextind(s, i)
    props = Pair{String,Any}[]
    while true
        i = _skip_ws(s, i)
        i > lastindex(s) && error("unterminated [ in class expression")
        if s[i] == ']'
            return (props, nextind(s, i))
        end
        if s[i] == ';'
            i = nextind(s, i); continue
        end
        # predicate
        pred, i = _read_token(s, i)
        i = _skip_ws(s, i)
        # object
        if s[i] == '['
            node, i = _parse_bracket(s, i)
            push!(props, _localpred(pred) => node)
        elseif s[i] == '('
            lst, i = _parse_list(s, i)
            push!(props, _localpred(pred) => lst)
        else
            obj, i = _read_term(s, i)
            push!(props, _localpred(pred) => obj)
        end
    end
end

# Parse an RDF collection ( e1 e2 … ) ; each element is a term or nested [..].
function _parse_list(s::AbstractString, i::Int)
    @assert s[i] == '('
    i = nextind(s, i)
    items = Any[]
    while true
        i = _skip_ws(s, i)
        i > lastindex(s) && error("unterminated ( in class expression")
        if s[i] == ')'
            return (items, nextind(s, i))
        end
        if s[i] == '['
            node, i = _parse_bracket(s, i)
            push!(items, node)
        else
            t, i = _read_term(s, i)
            push!(items, t)
        end
    end
end

_skip_ws(s, i) = begin
    while i <= lastindex(s) && isspace(s[i]); i = nextind(s, i); end
    i
end

# Read a whitespace/structural-delimited token (predicate or simple term).
function _read_token(s::AbstractString, i::Int)
    start = i
    while i <= lastindex(s) && !isspace(s[i]) && s[i] ∉ ('[', ']', '(', ')', ';', ',')
        i = nextind(s, i)
    end
    (strip(s[start:prevind(s, i)]), i)
end

# Read a term object: an IRI <...>, a prefixed name, 'a', or a typed/quoted
# literal (keeps the literal text intact).
function _read_term(s::AbstractString, i::Int)
    if s[i] == '<'
        j = i
        while j <= lastindex(s) && s[j] != '>'; j = nextind(s, j); end
        return (s[i:j], nextind(s, j))
    elseif s[i] == '"' || s[i] == '\''
        q = s[i]; j = nextind(s, i)
        while j <= lastindex(s) && s[j] != q; j = nextind(s, j); end
        j = nextind(s, j)               # past closing quote
        # optional ^^datatype or @lang
        while j <= lastindex(s) && !isspace(s[j]) && s[j] ∉ (';', ']', ')', ',')
            j = nextind(s, j)
        end
        return (s[i:prevind(s, j)], j)
    else
        return _read_token(s, i)
    end
end

# Localname of a predicate token: strips a known prefix, returns the local part.
function _localpred(p::AbstractString)
    p = strip(p)
    p == "a" && return "type"
    if startswith(p, "<") && endswith(p, ">")
        full = p[2:end-1]
        return last(split(full, ('#', '/')))
    end
    occursin(":", p) && return last(split(p, ':'))
    p
end

# Find the value of a localname predicate in a parsed-bracket prop list.
function _getprop(props, key)
    for (k, v) in props
        k == key && return v
    end
    nothing
end

# Generate the SPARQL group pattern (a string of triple patterns / UNION / VALUES)
# that constrains `subj` (a SPARQL term string like "?x" or ":a") to be an
# instance of the parsed class-expression node `props`.
function _emit_classexpr(subj::AbstractString, props, st::_RWState)
    # When the closed graph is available, first try to find an equivalent class
    # node already materialized in the data and query its members directly. This
    # captures memberships entailed via equivalentClass / restrictions that a
    # syntactic BGP rewrite would miss (e.g. someValuesFrom owl:Thing).
    if st.g !== nothing
        node = _find_class_node(st.g, props, st.prefixes)
        if node !== nothing
            # Collect the materialized rdf:type members of the matched class node.
            # A bnode class node can't be named in SPARQL, so emit the members as a
            # VALUES set; a named node could be queried directly but VALUES is
            # uniform and avoids re-matching.
            members = _class_members(st.g, node)
            if members !== nothing
                isempty(members) && return "$subj a <http://www.w3.org/2002/07/owl#Nothing> ."
                return "VALUES $subj { " * join(members, " ") * " }"
            end
        end
    end
    # owl:intersectionOf ( C1 … Cn ) → conjunction
    inter = _getprop(props, "intersectionOf")
    if inter !== nothing
        return join([_emit_member(subj, c, st) for c in inter], " ")
    end
    # owl:unionOf ( C1 … Cn ) → UNION of memberships
    uni = _getprop(props, "unionOf")
    if uni !== nothing
        st.union_emitted = true
        parts = ["{ " * _emit_member(subj, c, st) * " }" for c in uni]
        return join(parts, " UNION ")
    end
    # owl:oneOf ( i1 … in ) → VALUES
    one = _getprop(props, "oneOf")
    if one !== nothing
        return "VALUES $subj { " * join(string.(one), " ") * " }"
    end
    # owl:complementOf C → best effort: subjects (that appear as instances) not in C
    comp = _getprop(props, "complementOf")
    if comp !== nothing
        f = _fresh(st)
        inner = _emit_member(subj, comp, st)
        return "$subj a $f . FILTER NOT EXISTS { $inner }"
    end
    # owl:Restriction
    onp = _getprop(props, "onProperty")
    if onp !== nothing
        p = onp isa AbstractString ? onp : error("bad onProperty")
        hv = _getprop(props, "hasValue")
        if hv !== nothing
            return "$subj $p $(hv) ."
        end
        sv = _getprop(props, "someValuesFrom")
        if sv !== nothing
            # someValuesFrom complementOf C: x satisfies "p some (not C)" if it has
            # an asserted p-filler not provably in C, OR (existentially) it is a
            # member of a graph restriction [p some D] with D ⊑ (not C) — which
            # holds when D is disjoint with C. Emit a UNION of both witnesses.
            if !(sv isa AbstractString)
                comp = _getprop(sv, "complementOf")
                if comp !== nothing && st.g !== nothing
                    members = _complement_some_nodes(st.g, st.prefixes, p, comp)
                    y = _fresh(st)
                    inner = _emit_member(y, sv, st)
                    asserted = "{ $subj $p $y . $inner }"
                    if members !== nothing && !isempty(members)
                        st.union_emitted = true
                        return asserted * " UNION { VALUES $subj { " * join(members, " ") * " } }"
                    end
                    return "$subj $p $y . $inner"
                end
            end
            y = _fresh(st)
            inner = _emit_member(y, sv, st)
            return "$subj $p $y . $inner"
        end
        av = _getprop(props, "allValuesFrom")
        if av !== nothing
            # Non-vacuous all-values: x must HAVE a p-value, and have NO p-value
            # outside the class. (The W3C expected answers exclude individuals
            # with no p-value.)
            y = _fresh(st); z = _fresh(st)
            inner = _emit_member(z, av, st)
            return "$subj $p $y . FILTER NOT EXISTS { $subj $p $z . FILTER NOT EXISTS { $inner } }"
        end
        onc = _getprop(props, "onClass")
        # owl:minCardinality n (n≥1) on p  ≡  p some owl:Thing.
        mincard = _card_value(_getprop(props, "minCardinality"))
        if mincard !== nothing && mincard >= 1
            y = _fresh(st)
            return "$subj $p $y ."
        end
        # owl:minQualifiedCardinality n (n≥1) onClass C  ≡  p some C.
        minq = _card_value(_getprop(props, "minQualifiedCardinality"))
        if minq !== nothing && minq >= 1
            if onc !== nothing
                y = _fresh(st)
                inner = _emit_member(y, onc, st)
                return "$subj $p $y . $inner"
            else
                y = _fresh(st)
                return "$subj $p $y ."
            end
        end
        # owl:max/exactlyQualifiedCardinality n onClass C: a max/exact ≤/=n bound
        # can only be PROVEN for an individual whose p-fillers are CLOSED in the
        # data (e.g. an allValuesFrom-of-oneOf on the same property bounds them).
        # Compute the qualifying individuals from the closed graph by counting.
        maxq = _card_value(_getprop(props, "maxQualifiedCardinality"))
        exq  = _card_value(_getprop(props, "qualifiedCardinality"))
        if (maxq !== nothing || exq !== nothing) && onc !== nothing && st.g !== nothing
            inds = _closed_qualified_cardinality(st.g, st.prefixes, p, onc,
                       maxq !== nothing ? maxq : exq, exq !== nothing)
            if inds !== nothing
                isempty(inds) && return "$subj a <http://www.w3.org/2002/07/owl#Nothing> ."
                return "VALUES $subj { " * join(inds, " ") * " }"
            end
        end
    end
    # Fallback: just require the subject to be typed something (no constraint we
    # can express) — emit nothing meaningful; match nothing rather than all.
    return "$subj a <http://www.w3.org/2002/07/owl#Nothing> ."
end

# Emit "subj is a member of class C", where C is a term string or a nested node.
function _emit_member(subj::AbstractString, c, st::_RWState)
    if c isa AbstractString
        return "$subj a $c ."
    else  # nested class-expression node (Vector of Pairs)
        return _emit_classexpr(subj, c, st)
    end
end

# ─── graph-aware helpers (structural class match, closed cardinality) ───

# Parse the integer value of a cardinality object term (e.g. a typed literal
# `"1"^^xsd:nonNegativeInteger`, or a bare `1`). Returns nothing if not numeric.
function _card_value(term)
    term isa AbstractString || return nothing
    s = strip(term)
    m = match(r"^\"?(-?\d+)\"?", s)   # strip optional quotes / ^^datatype tail
    m === nothing && return nothing
    tryparse(Int, m.captures[1])
end

# Extract the PREFIX declarations of a query into a localname-prefix → IRI map,
# also recording the empty prefix (`:`) and `base`.
function _query_prefixes(query::AbstractString)
    pre = Dict{String,String}()
    for m in eachmatch(r"(?i)\bPREFIX\s+([A-Za-z0-9_.-]*):\s*<([^>]*)>", query)
        pre[m.captures[1]] = m.captures[2]
    end
    pre
end

# Resolve a class-expression term string (`owl:Thing`, `:Female`, `<...>`, `a`)
# to a URIRef using the query's prefixes. Returns nothing when it is not a simple
# IRI/prefixed name (e.g. a literal).
function _resolve_term(term::AbstractString, prefixes)
    t = strip(term)
    (isempty(t) || t == "a") && return nothing
    if startswith(t, "<") && endswith(t, ">")
        return URIRef(t[2:end-1])
    end
    startswith(t, "\"") && return nothing
    idx = findfirst(==(':'), t)
    idx === nothing && return nothing
    pfx = t[1:idx-1]; local_ = t[idx+1:end]
    ns = get(prefixes, pfx, nothing)
    ns === nothing && return nothing
    URIRef(ns * local_)
end

# Render a graph node as a SPARQL term string (IRIs only; bnodes can't be named
# safely in a query, so structural matches on a bnode class node are emitted via
# its IRI — when the matched class node is a bnode we return nothing so the caller
# falls back to a BGP rewrite).
_node_term(n) = n isa URIRef ? "<$(n.value)>" : nothing

# Named (URIRef) rdf:type members of a class node in the closed graph, as SPARQL
# term strings. Returns nothing if the class node has no named members at all (so
# the caller can decide whether to fall back); otherwise the (deduplicated) set.
function _class_members(g::RDFGraph, node)
    rdf_type = URIRef(_RDF_NS * "type")
    out = String[]
    seen = Set{URIRef}()
    for t in triples(g, (nothing, rdf_type, node))
        s = t.subject
        s isa URIRef || continue
        s in seen && continue
        push!(seen, s); push!(out, "<$(s.value)>")
    end
    out
end

# Find a class node in the (closed) graph `g` whose definition structurally
# matches the parsed class expression `props`. Used to query the materialized
# membership of an equivalent named/anonymous class rather than re-deriving it.
# Currently matches owl:Restriction expressions (onProperty + someValuesFrom /
# allValuesFrom / hasValue). Returns a Node (URIRef preferred) or nothing.
function _find_class_node(g::RDFGraph, props, prefixes)
    onp = _getprop(props, "onProperty")
    onp isa AbstractString || return nothing
    prop = _resolve_term(onp, prefixes)
    prop isa URIRef || return nothing
    # Determine the someValuesFrom filler this restriction is equivalent to.
    # minCardinality n≥1 ≡ someValuesFrom owl:Thing; minQualifiedCardinality n≥1
    # onClass C ≡ someValuesFrom C. These let cardinality restrictions reuse the
    # materialized membership of an equivalent someValuesFrom class.
    sv = _getprop(props, "someValuesFrom")
    filler = nothing
    if sv isa AbstractString
        filler = _resolve_term(sv, prefixes)
    else
        mincard = _card_value(_getprop(props, "minCardinality"))
        minq    = _card_value(_getprop(props, "minQualifiedCardinality"))
        if mincard !== nothing && mincard >= 1
            filler = URIRef(_OWL * "Thing")
        elseif minq !== nothing && minq >= 1
            onc = _getprop(props, "onClass")
            filler = onc isa AbstractString ? _resolve_term(onc, prefixes) : URIRef(_OWL * "Thing")
        end
    end
    filler isa URIRef || return nothing

    onProperty = URIRef(_OWL * "onProperty")
    someValuesFrom = URIRef(_OWL * "someValuesFrom")
    best = nothing
    for t in triples(g, (nothing, someValuesFrom, filler))
        node = t.subject
        node isa Node || continue
        # confirm same onProperty
        any(tt -> tt.object == prop, triples(g, (node, onProperty, nothing))) || continue
        # Prefer a URIRef node (nameable) over a bnode.
        if best === nothing || (best isa BNode && node isa URIRef)
            best = node
        end
    end
    best
end

# Closed-role qualified-cardinality counting. An individual `x` provably
# satisfies `max n` / `exactly n` `q onClass C` only if its q-fillers are CLOSED
# in the data — i.e. x is asserted (directly or via type) to fall under an
# allValuesFrom restriction on `q` whose filler is an owl:oneOf enumeration, so
# every q-filler of x is among a known finite set. For such x we count its
# distinct q-fillers that are (provably) of class C and test the bound. Returns
# the Vector of qualifying SPARQL term strings, or nothing if the pattern cannot
# be evaluated (then the caller leaves the restriction unsatisfiable).
function _closed_qualified_cardinality(g::RDFGraph, prefixes, q_str, onc, bound::Int, exact::Bool)
    q = _resolve_term(q_str, prefixes)
    q isa URIRef || return nothing
    onc isa AbstractString || return nothing
    cls = _resolve_term(onc, prefixes)
    cls isa URIRef || return nothing

    rdf_type   = URIRef(_RDF_NS * "type")
    onProperty = URIRef(_OWL * "onProperty")
    allValues  = URIRef(_OWL * "allValuesFrom")
    oneOf      = URIRef(_OWL * "oneOf")

    # Restriction nodes that CLOSE property q via allValuesFrom an oneOf class.
    closing = Set{Node}()
    for t in triples(g, (nothing, allValues, nothing))
        rnode = t.subject; filler = t.object
        rnode isa Node || continue
        any(tt -> tt.object == q, triples(g, (rnode, onProperty, nothing))) || continue
        # filler must be (or be a class with) an owl:oneOf enumeration.
        filler isa Node || continue
        any(_ -> true, triples(g, (filler, oneOf, nothing))) || continue
        push!(closing, rnode)
    end
    isempty(closing) && return String[]   # no individual has a closed q-role

    # Individuals whose type includes one of the closing restriction nodes.
    qualifying = String[]
    seen = Set{Node}()
    for rnode in closing
        for t in triples(g, (nothing, rdf_type, rnode))
            x = t.subject
            x isa URIRef || continue
            x in seen && continue
            push!(seen, x)
            # Count distinct q-fillers of x that are provably of class C.
            fillers = Set{Node}()
            for ft in triples(g, (x, q, nothing))
                y = ft.object
                y isa Node || continue
                any(_ -> true, triples(g, (y, rdf_type, cls))) && push!(fillers, y)
            end
            cnt = length(fillers)
            ok = exact ? (cnt == bound) : (cnt <= bound)
            ok && push!(qualifying, "<$(x.value)>")
        end
    end
    qualifying
end

# For a query restriction `[p some (complementOf C)]`, find graph restriction
# nodes `[p some D]` whose filler D is disjoint with C (hence D ⊑ not C, so any
# instance of `[p some D]` is an instance of `[p some (not C)]`). Returns the
# Vector of SPARQL term strings for the matching (named) restriction nodes, or
# nothing when C is not a simple class term.
function _complement_some_nodes(g::RDFGraph, prefixes, p_str, comp)
    comp isa AbstractString || return nothing
    C = _resolve_term(comp, prefixes)
    C isa URIRef || return nothing
    p = _resolve_term(p_str, prefixes)
    p isa URIRef || return nothing

    onProperty   = URIRef(_OWL * "onProperty")
    someValues   = URIRef(_OWL * "someValuesFrom")
    disjointWith = URIRef(_OWL * "disjointWith")

    # Classes disjoint with C (symmetric).
    disj = Set{Node}()
    for t in triples(g, (C, disjointWith, nothing)); t.object isa Node && push!(disj, t.object); end
    for t in triples(g, (nothing, disjointWith, C)); t.subject isa Node && push!(disj, t.subject); end
    isempty(disj) && return String[]

    # For each disjoint class D, find restriction nodes [p some D] and collect the
    # named individuals that are members of those restriction classes. (Restriction
    # nodes are often blank, so we return members rather than node names.)
    out = String[]
    seen = Set{URIRef}()
    for d in disj
        for t in triples(g, (nothing, someValues, d))
            node = t.subject
            node isa Node || continue
            any(tt -> tt.object == p, triples(g, (node, onProperty, nothing))) || continue
            for m in _class_members(g, node)
                # _class_members returns SPARQL term strings; dedup by string.
                m in out || push!(out, m)
            end
        end
    end
    out
end

# Inline a class expression defined on a labelled node (a query blank node `_:c`
# or a variable) and referenced via `?x a NODE`. Turns
#     ?x a _:c .  _:c owl:intersectionOf ( :A :B ) .
# into
#     ?x a [ owl:intersectionOf ( :A :B ) ] .
# so the bracket rewriter can take over. Only handles a single such definition
# whose body is one `owl:intersectionOf/unionOf/oneOf ( … )` triple — sufficient
# for the variable-referenced anonymous-class entailment tests.
function _inline_bnode_classes(query::AbstractString)
    m = match(r"(?is)(_:[A-Za-z0-9_]+|[?$][A-Za-z0-9_]+)\s+owl:(intersectionOf|unionOf|oneOf)\s*\(([^)]*)\)\s*\.?", query)
    m === nothing && return String(query)
    label = m.captures[1]; kw = m.captures[2]; lst = m.captures[3]
    elabel = replace(label, r"([?$])" => s"\\\1")  # escape regex metachars
    # Remove the definition triple.
    q = replace(query, m.match => " ")
    # Replace `?x a LABEL` / `?x rdf:type LABEL` with the inline bracket.
    bracket = "[ owl:$kw ( $(strip(lst)) ) ]"
    pat = Regex("(\\ba\\b|rdf:type)\\s+" * elabel * "(\\s*[.;}])")
    q = replace(q, pat => SubstitutionString("\\1 " * bracket * "\\2"))
    q
end

# Replace a labelled query blank node `_:label` with a fresh SPARQL variable, but
# ONLY when that blank node is the subject of an inline class expression that we
# will rewrite (`_:label a [ … ]` / `_:label rdf:type [ … ]`). Our restriction
# rewrites can bind the subject via a VALUES clause, which requires a variable;
# a query blank node there is a non-distinguished variable, so this is faithful.
# Blank nodes used elsewhere (e.g. `?C rdfs:subClassOf _:b . _:b a owl:Restriction`
# where _:b directly matches a data restriction node) are left untouched.
function _bnodes_to_vars(query::AbstractString)
    labels = String[]
    for m in eachmatch(r"_:([A-Za-z0-9_]+)\s+(?:a|rdf:type)\s*\[", query)
        push!(labels, m.captures[1])
    end
    isempty(labels) && return String(query)
    unique!(labels)
    q = String(query)
    for lab in labels
        q = replace(q, Regex("_:" * lab * "\\b") => "?__owlbn_" * lab)
    end
    q
end

# Detect and rewrite anonymous class-expression patterns in a query string.
# Returns the rewritten query (unchanged if no such pattern is present). When the
# (entailment-closed) data graph `g` is supplied, the rewriter additionally
# performs structural class matching, cardinality normalization, and closed-role
# cardinality counting against the materialized data.
function rewrite_owl_query(query::AbstractString, g::Union{Nothing,RDFGraph} = nothing)
    query = _inline_bnode_classes(query)
    # Quick reject: only act when an owl class-expression keyword sits inside a
    # bracket in the query (intersectionOf/unionOf/oneOf/Restriction/onProperty/
    # complementOf/someValuesFrom/allValuesFrom/hasValue/cardinalities).
    occursin(r"owl:(intersectionOf|unionOf|oneOf|Restriction|onProperty|complementOf|someValuesFrom|allValuesFrom|hasValue|[a-zA-Z]*[cC]ardinality|onClass)"i, query) ||
        occursin("Restriction", query) || return String(query)

    # A query blank node (`_:b0`) that roots / is bound around a rewritten class
    # expression must become a real variable: our restriction rewrites can emit a
    # VALUES clause on the subject, and VALUES requires a variable. Query blank
    # nodes are semantically non-distinguished variables, so this is faithful.
    query = _bnodes_to_vars(query)

    out = IOBuffer()
    st = _RWState(0, g, _query_prefixes(query))
    i = firstindex(query)
    n = lastindex(query)
    changed = false
    while i <= n
        # Look for `SUBJ (a|rdf:type|<...type>) [` triple pattern.
        m = _match_type_bracket(query, i)
        if m === nothing
            write(out, query[i:n]); break
        end
        pre_end, subj, bracket_start = m
        # write everything up to (not including) the subject token
        write(out, query[i:prevind(query, pre_end)])
        props, after = _parse_bracket(query, bracket_start)
        replacement = _emit_classexpr(subj, props, st)
        write(out, replacement)
        # Skip an optional trailing ' .' that ended the original triple, since our
        # replacement already terminates its patterns.
        j = _skip_ws(query, after)
        if j <= n && query[j] == '.'
            after = nextind(query, j)
        end
        i = after
        changed = true
    end
    changed || return String(query)
    result = String(take!(out))
    # Our someValuesFrom/allValuesFrom rewrites introduce fresh helper variables.
    # Under `SELECT *` those would leak into the projection, so replace a bare
    # `SELECT *` with an explicit projection of just the ORIGINAL query variables.
    if st.n > 0
        m = match(r"(?is)\bSELECT\s+(DISTINCT\s+|REDUCED\s+)?\*", result)
        if m !== nothing
            origvars = unique(String.(m_.match for m_ in eachmatch(r"[?$][A-Za-z_][A-Za-z0-9_]*", query)))
            filter!(v -> !startswith(v, "?__owlx") && !startswith(v, "?__owlbn"), origvars)
            if !isempty(origvars)
                proj = (m.captures[1] === nothing ? "" : m.captures[1]) * join(origvars, " ")
                result = replace(result, m.match => "SELECT " * proj; count = 1)
            end
        end
    end
    # A union-of-class rewrite can yield spurious duplicate rows for individuals
    # that belong to several union members. OWL entailment query answers are
    # set-based, so make such a rewritten SELECT DISTINCT (only when we are sure a
    # UNION was introduced — other rewrites preserve the original multiplicity,
    # which some sameAs tests depend on).
    if st.union_emitted
        result = replace(result, r"(?is)\bSELECT\b(?!\s+(DISTINCT|REDUCED)\b)" => "SELECT DISTINCT"; count = 1)
    end
    result
end

# Find the next `SUBJECT a|rdf:type|<…#type> [` occurrence at/after index `i`.
# Returns (subject_start_index, subject_token, bracket_index) or nothing.
function _match_type_bracket(s::AbstractString, i::Int)
    n = lastindex(s)
    while i <= n
        # candidate subject token start: a variable or term, preceded by a
        # group/triple boundary. Scan for '[' and back up to find its predicate.
        if s[i] == '['
            # back up over whitespace to the predicate
            k = prevind(s, i)
            k = _rskip_ws(s, k)
            pred_end = k
            # read predicate backwards
            pk = k
            while pk >= firstindex(s) && !isspace(s[pk]) && s[pk] ∉ ('{', '.', ';', '(', ')', '}')
                pk = prevind(s, pk)
            end
            pred = strip(s[nextind(s, pk):pred_end])
            if pred == "a" || pred == "rdf:type" || _localpred(pred) == "type"
                # read subject backwards
                sk = _rskip_ws(s, pk)
                ssk = sk
                while ssk >= firstindex(s) && !isspace(s[ssk]) && s[ssk] ∉ ('{', '.', ';', '}')
                    ssk = prevind(s, ssk)
                end
                subj = strip(s[nextind(s, ssk):sk])
                if !isempty(subj)
                    return (nextind(s, ssk), subj, i)
                end
            end
        end
        i = nextind(s, i)
    end
    nothing
end

_rskip_ws(s, i) = begin
    while i >= firstindex(s) && isspace(s[i]); i = prevind(s, i); end
    i
end

# The set of blank nodes that are OWL "structural" nodes — anonymous class
# expressions, restrictions, or RDF-list cells used by them. Under the SPARQL
# entailment regimes, query answers must not bind variables to such surrogate
# blank nodes (cf. rdfs13). Data blank nodes that are genuine individuals are
# kept (e.g. owlds02 returns a real bnode object).
function _structural_bnodes(g::RDFGraph)
    out = Set{BNode}()
    structural_preds = (URIRef(_OWL * "intersectionOf"), URIRef(_OWL * "unionOf"),
        URIRef(_OWL * "oneOf"), URIRef(_OWL * "onProperty"), URIRef(_OWL * "someValuesFrom"),
        URIRef(_OWL * "allValuesFrom"), URIRef(_OWL * "hasValue"), URIRef(_OWL * "complementOf"),
        URIRef(_OWL * "onClass"), URIRef(_OWL * "equivalentClass"))
    rdf_type = URIRef(_RDF_NS * "type")
    for p in structural_preds
        for t in triples(g, (nothing, p, nothing))
            t.subject isa BNode && push!(out, t.subject)
        end
    end
    for cls in (URIRef(_OWL * "Restriction"), URIRef(_OWL * "Class"))
        for t in triples(g, (nothing, rdf_type, cls))
            t.subject isa BNode && push!(out, t.subject)
        end
    end
    # Mark RDF-list cells reachable from a structural node's list as structural too.
    nil = URIRef(_RDF_NS * "nil"); first_ = URIRef(_RDF_NS * "first"); rest_ = URIRef(_RDF_NS * "rest")
    frontier = collect(out)
    seen = Set{BNode}()
    while !isempty(frontier)
        node = pop!(frontier)
        node in seen && continue
        push!(seen, node)
        for t in triples(g, (node, nothing, nothing))
            o = t.object
            o isa BNode || continue
            (push!(out, o); push!(frontier, o))
        end
    end
    out
end

"""
    filter_entailment_results(g, rows) -> rows

Drop solution rows that bind any variable to an OWL structural (surrogate) blank
node of `g`. Returns `rows` unchanged when it is not a Vector of solution dicts
(e.g. ASK Bool or a CONSTRUCT graph).
"""
function filter_entailment_results(g::RDFGraph, rows)
    rows isa Vector || return rows
    sb = _structural_bnodes(g)
    isempty(sb) && return rows
    keep = similar(rows, 0)
    for r in rows
        bad = false
        for (_, v) in r
            if v isa BNode && v in sb
                bad = true; break
            end
        end
        bad || push!(keep, r)
    end
    keep
end

"""
    sparql_query_entailment(g_or_ds, query; regimes)

Answer `query` over a graph/dataset under the SPARQL entailment regime(s)
`regimes`: materialize the regime closure on the default graph (already done by
the caller when a Dataset is passed pre-closed), rewrite anonymous OWL
class-expression patterns to equivalent BGPs, and evaluate. The closure is the
caller's responsibility via [`materialize_entailment!`]; this function performs
the query rewriting and evaluation.
"""
function sparql_query_entailment(target, query::AbstractString; rewrite::Bool = true)
    q = rewrite ? rewrite_owl_query(query) : String(query)
    sparql_query(target, q)
end
