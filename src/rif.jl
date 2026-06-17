# ─── RIF Core entailment support ──────────────────────────────────────────
#
# Minimal RIF/XML (Rule Interchange Format) reader + forward-chaining
# materializer, used by the W3C SPARQL entailment regime tests (ent:RIF).
#
# A `.rif` document carries:
#   * a payload `<Group>` of `<sentence>`s. Each sentence is either
#       - a ground fact: a bare `<Frame>` (or `<And>` of Frames) with no
#         variables → RDF triples added directly, or
#       - a `<Forall> … <Implies><if>BODY</if><then>HEAD</then></Implies>`
#         universally-quantified rule.
#   * optional `<directive><Import><location>URL</location>…</Import>` clauses
#     that bring in EXTERNAL RDF data (Turtle / RDF-XML / OWL Functional Syntax).
#
# Materialization strategy: translate each rule to a SPARQL
#   CONSTRUCT { head } WHERE { body }
# string and evaluate it with the (conformant) SPARQL engine, adding the
# constructed triples back to the data graph, looping to a naive fixpoint.
# This reuses the join machinery rather than re-implementing it.
#
# A `<Frame>` is `<object>T</object> <slot><Const …>P</Const> V</slot>…`;
# each slot yields the triple (T, P, V). `<Var>x</Var>` ⇒ SPARQL `?x`,
# `<Const type="…iri">IRI</Const>` ⇒ a URIRef, other `<Const>` types ⇒ a
# typed/plain Literal.

using EzXML
import HTTP

const RIF_NS = "http://www.w3.org/2007/rif#"
const _RIF_RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

# A triple pattern: subject/predicate/object are each either an Identifier
# (ground term) or a `Variable` (RIF `<Var>`).
struct RIFTriplePattern
    s::Identifier
    p::Identifier
    o::Identifier
end

# A RIF rule: body & head are conjunctions of triple patterns.
struct RIFRule
    body::Vector{RIFTriplePattern}
    head::Vector{RIFTriplePattern}
end

# A parsed RIF document.
struct RIFDocument
    facts::Vector{Triple}            # ground triples
    rules::Vector{RIFRule}           # Forall/Implies rules
    imports::Vector{String}          # Import <location> URLs
end

# ─── XML helpers ───────────────────────────────────────────────────────────

# Child *element* nodes whose local-name == `name`.
function _rif_children(node, name::AbstractString)
    out = EzXML.Node[]
    for c in EzXML.eachelement(node)
        EzXML.nodename(c) == name && push!(out, c)
    end
    out
end

# First child element with the given local-name, or nothing.
function _rif_child(node, name::AbstractString)
    for c in EzXML.eachelement(node)
        EzXML.nodename(c) == name && return c
    end
    nothing
end

# Datatype IRI carried in a `<Const type="…">` attribute → concrete term.
# A `…rif#iri` const is a URIRef; `…rif#local` is treated as a (skolem) URIRef
# under a local namespace; everything else is a typed Literal (xs:string ⇒ plain).
const _XSD_STRING = "http://www.w3.org/2001/XMLSchema#string"
const _RIF_LOCAL_NS = "http://www.w3.org/2007/rif-local#"

function _rif_const_term(node)
    typ = haskey(node, "type") ? node["type"] : ""
    txt = strip(EzXML.nodecontent(node))
    if typ == RIF_NS * "iri"
        return URIRef(txt)
    elseif typ == RIF_NS * "local"
        return URIRef(_RIF_LOCAL_NS * txt)
    elseif typ == _XSD_STRING || isempty(typ)
        return Literal(String(txt))
    else
        return Literal(String(txt); datatype = URIRef(typ))
    end
end

# A RIF term node (`<Var>` or `<Const>`) → Identifier or Variable.
function _rif_term(node)
    nm = EzXML.nodename(node)
    if nm == "Var"
        return Variable(strip(EzXML.nodecontent(node)))
    elseif nm == "Const"
        return _rif_const_term(node)
    else
        error("RIF: unexpected term node <$nm>")
    end
end

# The single term child (Var/Const) of a wrapper element like <object>.
function _rif_term_child(node)
    for c in EzXML.eachelement(node)
        nm = EzXML.nodename(c)
        (nm == "Var" || nm == "Const") && return _rif_term(c)
    end
    error("RIF: no Var/Const term under <$(EzXML.nodename(node))>")
end

# ─── Frame / conjunction parsing ───────────────────────────────────────────

# Parse a <Frame> into one pattern per slot.
function _rif_frame(frame)::Vector{RIFTriplePattern}
    objnode = _rif_child(frame, "object")
    objnode === nothing && error("RIF: <Frame> without <object>")
    subj = _rif_term_child(objnode)
    out = RIFTriplePattern[]
    for slot in _rif_children(frame, "slot")
        terms = [c for c in EzXML.eachelement(slot)
                 if EzXML.nodename(c) in ("Var", "Const")]
        length(terms) >= 2 || error("RIF: <slot> needs predicate + value")
        pred = _rif_term(terms[1])
        val  = _rif_term(terms[2])
        push!(out, RIFTriplePattern(subj, pred, val))
    end
    out
end

# Parse a formula that is a conjunction of Frames: a bare <Frame>, or an
# <And> whose <formula> children wrap Frames. Returns the flat pattern list.
function _rif_conjunction(node)::Vector{RIFTriplePattern}
    nm = EzXML.nodename(node)
    if nm == "Frame"
        return _rif_frame(node)
    elseif nm == "And"
        out = RIFTriplePattern[]
        for f in _rif_children(node, "formula")
            inner = _rif_formula_body(f)
            inner === nothing && continue
            append!(out, _rif_conjunction(inner))
        end
        return out
    elseif nm == "formula"
        inner = _rif_formula_body(node)
        inner === nothing && return RIFTriplePattern[]
        return _rif_conjunction(inner)
    else
        error("RIF: unsupported conjunction node <$nm>")
    end
end

# The meaningful child of a <formula>/<if>/<then> wrapper (And/Frame/Implies…),
# skipping non-element nodes.
function _rif_formula_body(node)
    for c in EzXML.eachelement(node)
        nm = EzXML.nodename(c)
        nm in ("And", "Or", "Frame", "Implies", "Atom", "Member", "Subclass") && return c
    end
    nothing
end

# ─── Sentence parsing ──────────────────────────────────────────────────────

# A pattern with no Variable is ground → an RDF Triple.
_rif_is_ground(p::RIFTriplePattern) =
    !(p.s isa Variable) && !(p.p isa Variable) && !(p.o isa Variable)

_rif_to_triple(p::RIFTriplePattern) = Triple(p.s, p.p, p.o)

# Parse one <sentence> into the document, appending facts/rules.
function _rif_sentence!(doc::RIFDocument, sentence)
    body = nothing
    for c in EzXML.eachelement(sentence)
        nm = EzXML.nodename(c)
        if nm == "Forall"
            body = c
            break
        elseif nm in ("Frame", "And", "Implies")
            body = c
            break
        end
    end
    body === nothing && return doc
    nm = EzXML.nodename(body)

    if nm == "Forall"
        # <Forall> <declare>… <formula><Implies>…</Implies></formula> </Forall>
        fformula = nothing
        for c in _rif_children(body, "formula")
            inner = _rif_formula_body(c)
            inner !== nothing && EzXML.nodename(inner) == "Implies" && (fformula = inner; break)
        end
        if fformula === nothing
            # Forall wrapping a ground/quantified non-implication: try a Frame.
            for c in _rif_children(body, "formula")
                inner = _rif_formula_body(c)
                inner === nothing && continue
                for p in _rif_conjunction(inner)
                    _rif_is_ground(p) && push!(doc.facts, _rif_to_triple(p))
                end
            end
            return doc
        end
        _rif_implies!(doc, fformula)
    elseif nm == "Implies"
        _rif_implies!(doc, body)
    else  # ground Frame / And of Frames
        for p in _rif_conjunction(body)
            _rif_is_ground(p) && push!(doc.facts, _rif_to_triple(p))
        end
    end
    doc
end

function _rif_implies!(doc::RIFDocument, implies)
    ifnode   = _rif_child(implies, "if")
    thennode = _rif_child(implies, "then")
    (ifnode === nothing || thennode === nothing) && return doc
    ifbody   = _rif_formula_body(ifnode)
    thenbody = _rif_formula_body(thennode)
    (ifbody === nothing || thenbody === nothing) && return doc
    body = _rif_conjunction(ifbody)
    head = _rif_conjunction(thenbody)
    (isempty(body) || isempty(head)) && return doc
    push!(doc.rules, RIFRule(body, head))
    doc
end

# ─── Document parsing ──────────────────────────────────────────────────────

"""
    parse_rif(xml::AbstractString) -> RIFDocument

Parse a RIF/XML document string into ground facts, Forall/Implies rules, and
Import locations.
"""
function parse_rif(xml::AbstractString)
    docxml = EzXML.parsexml(xml)
    _parse_rif_doc(EzXML.root(docxml))
end

"""
    parse_rif_file(path) -> RIFDocument

Parse a RIF/XML file (handles DTD entity expansion, e.g. `&rif;`).
"""
function parse_rif_file(path::AbstractString)
    docxml = EzXML.readxml(path)
    _parse_rif_doc(EzXML.root(docxml))
end

function _parse_rif_doc(rootnode)
    doc = RIFDocument(Triple[], RIFRule[], String[])
    # directives → imports
    for dir in _rif_children(rootnode, "directive")
        for imp in _rif_children(dir, "Import")
            loc = _rif_child(imp, "location")
            loc === nothing && continue
            push!(doc.imports, strip(EzXML.nodecontent(loc)))
        end
    end
    payload = _rif_child(rootnode, "payload")
    payload === nothing && return doc
    group = _rif_child(payload, "Group")
    group === nothing && return doc
    for sentence in _rif_children(group, "sentence")
        _rif_sentence!(doc, sentence)
    end
    doc
end

# ─── SPARQL serialization of patterns (for CONSTRUCT/WHERE) ─────────────────

_rif_pat_term(t) = t isa Variable ? "?" * t.name : n3(t)

function _rif_pat_sparql(p::RIFTriplePattern)
    string(_rif_pat_term(p.s), " ", _rif_pat_term(p.p), " ", _rif_pat_term(p.o), " .")
end

# Build a `CONSTRUCT { head } WHERE { body }` query string for a rule.
function _rif_rule_query(rule::RIFRule)
    head = join((_rif_pat_sparql(p) for p in rule.head), "\n  ")
    body = join((_rif_pat_sparql(p) for p in rule.body), "\n  ")
    string("CONSTRUCT {\n  ", head, "\n} WHERE {\n  ", body, "\n}")
end

# ─── Forward chaining ──────────────────────────────────────────────────────

"""
    rif_forward_chain!(g, rules; max_iters=100) -> g

Apply RIF rules to graph `g` to a naive fixpoint by repeatedly running each
rule as a SPARQL CONSTRUCT and adding any new triples, until no rule produces
a new triple (or `max_iters` is reached).
"""
function rif_forward_chain!(g::RDFGraph, rules::Vector{RIFRule}; max_iters::Int = 100)
    isempty(rules) && return g
    queries = String[_rif_rule_query(r) for r in rules]
    for _ in 1:max_iters
        added = false
        for q in queries
            constructed = try
                sparql_query(g, q)
            catch
                continue
            end
            constructed isa RDFGraph || continue
            for t in constructed
                if !(t in g)
                    add!(g, t)
                    added = true
                end
            end
        end
        added || break
    end
    g
end

# ─── Import / document loading ─────────────────────────────────────────────

# Sanitize a URL into a cache filename.
_rif_cache_name(url::AbstractString) =
    replace(String(url), r"[^A-Za-z0-9._-]" => "_")

# Parse fetched bytes into graph `g`, dispatching on content-type / sniffed
# syntax. Handles Turtle, N-Triples, RDF/XML and (minimal) OWL Functional
# Syntax. `base` is used for relative IRIs.
function _rif_parse_imported!(g::RDFGraph, text::AbstractString, content_type::AbstractString, base::AbstractString)
    ct = lowercase(content_type)
    body = lstrip(text)
    if occursin("rdf+xml", ct) || startswith(body, "<?xml") || startswith(body, "<rdf:RDF") || occursin("<rdf:RDF", first(body, 200))
        parse_rdfxml!(g, text; base = base)
    elseif occursin("turtle", ct) || occursin("n-triples", ct) || occursin("ntriples", ct)
        parse_turtle!(g, text; base = base)
    elseif startswith(body, "Namespace(") || startswith(body, "Ontology(") ||
           startswith(body, "Prefix(") || occursin(r"^\s*(Ontology|Namespace)\(", body)
        parse_owl_functional!(g, text)
    else
        # Last resort: try Turtle, then RDF/XML.
        try
            parse_turtle!(g, text; base = base)
        catch
            parse_rdfxml!(g, text; base = base)
        end
    end
    g
end

# Fetch a URL with content negotiation + on-disk caching. Returns
# (text, content_type) or throws on failure.
function _rif_fetch(url::AbstractString; cache_dir::Union{Nothing,AbstractString} = nothing, timeout::Int = 30)
    if cache_dir !== nothing
        cf = joinpath(cache_dir, _rif_cache_name(url))
        ctf = cf * ".ct"
        if isfile(cf)
            ct = isfile(ctf) ? read(ctf, String) : ""
            return (read(cf, String), ct)
        end
    end
    resp = HTTP.get(String(url);
                    headers = ["Accept" => "text/turtle, application/rdf+xml;q=0.9, application/n-triples;q=0.8, */*;q=0.1"],
                    readtimeout = timeout, connect_timeout = timeout, retry = false,
                    status_exception = true)
    text = String(resp.body)
    ct = ""
    for (k, v) in resp.headers
        lowercase(k) == "content-type" && (ct = v; break)
    end
    if cache_dir !== nothing
        try
            mkpath(cache_dir)
            cf = joinpath(cache_dir, _rif_cache_name(url))
            write(cf, text)
            write(cf * ".ct", ct)
        catch
        end
    end
    (text, ct)
end

# Load all imports declared in `doc` into graph `g`. Returns a vector of
# (url, ok::Bool, reason::String) describing each attempt.
function rif_load_imports!(g::RDFGraph, doc::RIFDocument; cache_dir = nothing, timeout::Int = 30)
    report = Tuple{String,Bool,String}[]
    for url in doc.imports
        try
            text, ct = _rif_fetch(url; cache_dir = cache_dir, timeout = timeout)
            _rif_parse_imported!(g, text, ct, url)
            push!(report, (url, true, ""))
        catch e
            push!(report, (url, false, first(sprint(showerror, e), 160)))
        end
    end
    report
end

# ─── Minimal OWL Functional Syntax → RDF triples ────────────────────────────
#
# Supports exactly the constructs needed by the brain-anatomy import:
#   Namespace(=<base>)                Prefix(:=<base>)  Prefix(p:=<iri>)
#   Ontology(<iri> … axioms …)
#   SubClassOf(A B)                   → A rdfs:subClassOf B
#   SymmetricObjectProperty(p)        → p a owl:SymmetricProperty
#   ObjectPropertyDomain(p C)         → p rdfs:domain C
#   ObjectPropertyRange(p E)          → p rdfs:range E   (E may be ObjectUnionOf)
#   ObjectUnionOf(C D)                → fresh bnode owl:unionOf (C D)
#   Declaration(NamedIndividual(x))   → x a owl:NamedIndividual
#   Declaration(Class(C)) / …Property → typed declaration
#   ClassAssertion(C x) | (x C)       → x a C
#   ObjectPropertyAssertion(p s o)    → s p o

const _OWL_NS  = "http://www.w3.org/2002/07/owl#"
const _RDFS_NS = "http://www.w3.org/2000/01/rdf-schema#"
const _RDF_NS  = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

# Tokenize OWL/FS into atoms: identifiers, IRIs (<…>), strings, parens.
function _owlfs_tokenize(s::AbstractString)
    toks = String[]
    i = firstindex(s); n = lastindex(s)
    while i <= n
        c = s[i]
        if isspace(c)
            i = nextind(s, i)
        elseif c == '('
            push!(toks, "("); i = nextind(s, i)
        elseif c == ')'
            push!(toks, ")"); i = nextind(s, i)
        elseif c == '='
            push!(toks, "="); i = nextind(s, i)
        elseif c == '<'
            j = findnext('>', s, i)
            j === nothing && error("OWL/FS: unterminated <IRI>")
            push!(toks, s[i:j]); i = nextind(s, j)
        elseif c == '"'
            j = nextind(s, i); buf = IOBuffer()
            while j <= n && s[j] != '"'
                if s[j] == '\\' && j < n
                    j = nextind(s, j)
                end
                print(buf, s[j]); j = nextind(s, j)
            end
            push!(toks, "\"" * String(take!(buf)) * "\"")
            i = j <= n ? nextind(s, j) : j
        else
            j = i
            while j <= n && !isspace(s[j]) && s[j] ∉ ('(', ')', '=', '<', '"')
                j = nextind(s, j)
            end
            push!(toks, s[i:prevind(s, j)])
            i = j
        end
    end
    # strip comment lines (#…) handled by caller via line filter; here treat
    toks
end

# A tiny recursive descent over the token stream producing nested S-expressions.
mutable struct _OWLFSParser
    toks::Vector{String}
    pos::Int
end

_owlfs_peek(p) = p.pos <= length(p.toks) ? p.toks[p.pos] : nothing
_owlfs_next(p) = (t = p.toks[p.pos]; p.pos += 1; t)

# Parse one S-expression: either an atom, or NAME( args… ).
function _owlfs_expr(p)
    t = _owlfs_next(p)
    nxt = _owlfs_peek(p)
    if nxt == "("
        _owlfs_next(p)  # consume '('
        args = Any[]
        while _owlfs_peek(p) != ")" && _owlfs_peek(p) !== nothing
            # skip stray '=' (Prefix(:=<iri>) / Namespace(=<iri>))
            if _owlfs_peek(p) == "="
                _owlfs_next(p); continue
            end
            push!(args, _owlfs_expr(p))
        end
        _owlfs_peek(p) == ")" && _owlfs_next(p)
        return (t, args)
    else
        return t
    end
end

# Remove a trailing '# comment' from one line, respecting <IRI> and "literal".
function _owlfs_strip_comment(line::AbstractString)
    in_iri = false; in_str = false
    for (idx, c) in pairs(line)
        if in_str
            c == '"' && (in_str = false)
        elseif in_iri
            c == '>' && (in_iri = false)
        elseif c == '<'
            in_iri = true
        elseif c == '"'
            in_str = true
        elseif c == '#'
            return line[1:prevind(line, idx)]
        end
    end
    line
end

"""
    parse_owl_functional!(g::RDFGraph, text) -> g

Parse a minimal subset of OWL 2 Functional Syntax into RDF triples in `g`.
"""
function parse_owl_functional!(g::RDFGraph, text::AbstractString)
    # strip line comments (# … to end of line), but NOT '#' inside <IRI> or
    # "string" literals (IRIs commonly contain a fragment '#').
    clean = join((_owlfs_strip_comment(l) for l in split(String(text), '\n')), "\n")
    toks = _owlfs_tokenize(clean)
    p = _OWLFSParser(toks, 1)
    prefixes = Dict{String,String}()
    base = Ref("")
    # Expand a term (IRI / prefixed name / abbreviated) to a full IRI string.
    function expand(tok::AbstractString)::String
        s = String(tok)
        if startswith(s, "<") && endswith(s, ">")
            return s[2:end-1]
        end
        idx = findfirst(':', s)
        if idx !== nothing
            pre = s[1:idx-1]
            rest = s[idx+1:end]
            if haskey(prefixes, pre)
                return prefixes[pre] * rest
            end
            # unknown prefix: leave as-is (full IRI?) — fall through
            return s
        end
        # no colon → relative to base
        return base[] * s
    end
    termU(tok) = URIRef(expand(tok))

    function add3(s, pr, o)
        add!(g, Triple(s, pr, o))
    end

    bnctr = Ref(0)
    freshb() = (bnctr[] += 1; BNode("owlfs$(bnctr[])"))

    # Resolve a class expression node → (term, side-effects added). Only
    # ObjectUnionOf is structured; otherwise an atom IRI.
    function classexpr(node)
        if node isa Tuple
            name, args = node
            if name == "ObjectUnionOf"
                members = [classexpr(a) for a in args]
                bn = freshb()
                # owl:unionOf list
                head = bn
                # build rdf:List
                nodes = members
                listhead = nothing
                prev = nothing
                for (k, m) in enumerate(nodes)
                    cell = freshb()
                    if listhead === nothing
                        listhead = cell
                    end
                    if prev !== nothing
                        add3(prev, URIRef(_RDF_NS * "rest"), cell)
                    end
                    add3(cell, URIRef(_RDF_NS * "first"), m)
                    prev = cell
                end
                prev !== nothing && add3(prev, URIRef(_RDF_NS * "rest"), URIRef(_RDF_NS * "nil"))
                add3(bn, URIRef(_RDF_NS * "type"), URIRef(_OWL_NS * "Class"))
                add3(bn, URIRef(_OWL_NS * "unionOf"), listhead === nothing ? URIRef(_RDF_NS * "nil") : listhead)
                return bn
            else
                # unsupported structured class → fresh bnode
                return freshb()
            end
        else
            return termU(node)
        end
    end

    # Walk top-level expressions.
    while _owlfs_peek(p) !== nothing
        expr = _owlfs_expr(p)
        expr isa Tuple || continue
        name, args = expr
        if name == "Prefix"
            # args: prefixname (possibly "p" then "=" already stripped) then <iri>
            # After '=' stripping, args = [prefixtoken_or_nothing, <iri>]
            iri = ""; pre = ""
            for a in args
                a isa Tuple && continue
                sa = String(a)
                if startswith(sa, "<")
                    iri = sa[2:end-1]
                elseif endswith(sa, ":")
                    pre = sa[1:end-1]
                else
                    pre = sa
                end
            end
            prefixes[pre] = iri
            (pre == "" ) && (base[] = iri)
        elseif name == "Namespace"
            iri = ""
            for a in args
                sa = a isa Tuple ? "" : String(a)
                startswith(sa, "<") && (iri = sa[2:end-1])
            end
            base[] = iri
            prefixes[""] = iri
        elseif name == "Ontology"
            # first arg may be the ontology IRI; remaining are axioms
            for (k, a) in enumerate(args)
                if a isa Tuple
                    _owlfs_axiom!(a, g, expand, termU, classexpr, add3, freshb)
                end
            end
        else
            _owlfs_axiom!(expr, g, expand, termU, classexpr, add3, freshb)
        end
    end
    g
end

# Process a single OWL/FS axiom S-expression.
function _owlfs_axiom!(expr, g, expand, termU, classexpr, add3, freshb)
    expr isa Tuple || return
    name, args = expr
    atoms = [a for a in args if !(a isa Tuple)]
    if name == "SubClassOf" && length(args) >= 2
        a = classexpr(args[1]); b = classexpr(args[2])
        add3(a, URIRef(_RDFS_NS * "subClassOf"), b)
    elseif name == "SymmetricObjectProperty" && length(args) >= 1
        add3(classexpr(args[1]), URIRef(_RDF_NS * "type"), URIRef(_OWL_NS * "SymmetricProperty"))
    elseif name == "ObjectPropertyDomain" && length(args) >= 2
        add3(classexpr(args[1]), URIRef(_RDFS_NS * "domain"), classexpr(args[2]))
    elseif name == "ObjectPropertyRange" && length(args) >= 2
        add3(classexpr(args[1]), URIRef(_RDFS_NS * "range"), classexpr(args[2]))
    elseif name == "Declaration" && length(args) >= 1 && args[1] isa Tuple
        dname, dargs = args[1]
        isempty(dargs) && return
        ent = classexpr(dargs[1])
        typ = dname == "NamedIndividual" ? _OWL_NS * "NamedIndividual" :
              dname == "Class" ? _OWL_NS * "Class" :
              dname == "ObjectProperty" ? _OWL_NS * "ObjectProperty" :
              dname == "DataProperty" ? _OWL_NS * "DatatypeProperty" :
              dname == "Individual" ? _OWL_NS * "NamedIndividual" : nothing
        typ !== nothing && add3(ent, URIRef(_RDF_NS * "type"), URIRef(typ))
    elseif name == "ClassAssertion" && length(args) >= 2
        # OWL2 order: ClassAssertion(Class Individual). Older order put the
        # individual first. Heuristic: whichever arg is a structured class expr
        # is the class; otherwise assume (Class, Individual).
        cls = classexpr(args[1]); ind = classexpr(args[2])
        add3(ind, URIRef(_RDF_NS * "type"), cls)
    elseif name == "ObjectPropertyAssertion" && length(args) >= 3
        pr = classexpr(args[1]); s = classexpr(args[2]); o = classexpr(args[3])
        add3(s, pr, o)
    end
    g
end

# ─── Top-level materialization ──────────────────────────────────────────────

"""
    rif_materialize!(g::RDFGraph, rif_path; cache_dir=nothing, timeout=30,
                     rdfs_first=true) -> (g, report)

Materialize a `.rif` rule document over data graph `g` in place:

  1. parse the RIF file (facts, rules, imports);
  2. add ground facts;
  3. fetch & load each Import's external RDF data (with caching);
  4. apply an RDFS subclass/subproperty/domain/range closure (so type
     hierarchies needed by rule bodies are present) and symmetric-property
     closure;
  5. forward-chain the RIF rules to a fixpoint, interleaving (4) so derived
     and imported facts both feed the rules.

Returns `(g, report)` where `report` is a NamedTuple with `imports` (the
per-import outcome) and `n_rules`/`n_facts`.
"""
function rif_materialize!(g::RDFGraph, rif_path::AbstractString;
                          cache_dir = nothing, timeout::Int = 30)
    doc = parse_rif_file(rif_path)
    for t in doc.facts
        add!(g, t)
    end
    import_report = rif_load_imports!(g, doc; cache_dir = cache_dir, timeout = timeout)

    # A couple of closure passes interleaved with rule firing: RDFS gives us
    # type/subclass entailments the rule bodies test; symmetric closure handles
    # owl:SymmetricProperty; then fire the RIF rules. Repeat to a small fixpoint.
    for _ in 1:8
        before = length(g)
        _rif_rdfs_lite!(g)
        _rif_symmetric!(g)
        rif_forward_chain!(g, doc.rules)
        length(g) == before && break
    end
    (g, (imports = import_report, n_rules = length(doc.rules), n_facts = length(doc.facts)))
end

"""
    rif_materialize(g, rif_path; …) -> (g2, report)

Non-mutating variant: copies `g` into a fresh graph, materializes, and returns it.
"""
function rif_materialize(g::RDFGraph, rif_path::AbstractString; kwargs...)
    g2 = RDFGraph()
    for t in g
        add!(g2, t)
    end
    rif_materialize!(g2, rif_path; kwargs...)
end

# A lightweight RDFS closure sufficient for the RIF tests: rdfs:subClassOf
# transitivity + type propagation, rdfs:subPropertyOf, domain/range. We reuse
# the library's RDFS closure when available, else do nothing extra.
function _rif_rdfs_lite!(g::RDFGraph)
    try
        rdfs_closure!(g)
    catch
    end
    g
end

# Symmetric property closure: for each p typed owl:SymmetricProperty, add the
# inverse triple (o p s) for every (s p o).
function _rif_symmetric!(g::RDFGraph)
    symprops = Set{URIRef}()
    symT = URIRef(_OWL_NS * "SymmetricProperty")
    typeP = URIRef(_RDF_NS * "type")
    for t in triples(g, (nothing, typeP, symT))
        t.subject isa URIRef && push!(symprops, t.subject)
    end
    isempty(symprops) && return g
    newts = Triple[]
    for p in symprops
        for t in triples(g, (nothing, p, nothing))
            inv = Triple(t.object isa Node ? t.object : t.object, p, t.subject)
            # only add if object can be a subject
            (t.object isa URIRef || t.object isa BNode) && push!(newts, Triple(t.object, p, t.subject))
        end
    end
    for t in newts
        t in g || add!(g, t)
    end
    g
end
