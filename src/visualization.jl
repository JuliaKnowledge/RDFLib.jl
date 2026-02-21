# ─── DOT Visualization ──────────────────────────────────────────────

"""
    _dot_escape(s::AbstractString) -> String

Escape special characters for DOT label strings.
"""
function _dot_escape(s::AbstractString)
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "<" => "\\<")
    s = replace(s, ">" => "\\>")
    s
end

"""
    _compact_uri(nsm::NamespaceManager, uri::URIRef) -> String

Try to produce a compact `prefix:localname` form; fall back to the full URI.
"""
function _compact_uri(nsm::NamespaceManager, uri::URIRef)
    try
        prefix, _, localname = compute_qname(nsm, uri)
        return string(prefix, ":", localname)
    catch
        return uri.value
    end
end

"""
    _dot_node_label(nsm::NamespaceManager, term::Identifier) -> String

Human-readable label for a term in a DOT graph.
"""
_dot_node_label(nsm::NamespaceManager, u::URIRef) = _compact_uri(nsm, u)
_dot_node_label(::NamespaceManager, b::BNode) = string("_:", b.id)

function _dot_node_label(::NamespaceManager, lit::Literal)
    s = lit.lexical
    if !isnothing(lit.language)
        s = string(s, "@", lit.language)
    elseif !isnothing(lit.datatype)
        s = string(s, "^^", lit.datatype.value)
    end
    s
end

"""
    to_dot(g::RDFGraph; label::AbstractString="RDF RDFGraph") -> String

Convert an RDF graph to a Graphviz DOT string for visualization.

URIRef nodes are shown as ellipses with compact URIs when possible.
BNodes are shown as small circles.
Literals are shown as rectangles.
Edges are labeled with the predicate (compact URI).

# Example
```julia
dot = to_dot(g)
# Write to file
open("graph.dot", "w") do f
    print(f, dot)
end
# Or pipe to dot: echo \$dot | dot -Tpng -o graph.png
```
"""
function to_dot(g::RDFGraph; label::AbstractString="RDF RDFGraph")
    buf = IOBuffer()
    to_dot(buf, g; label=label)
    String(take!(buf))
end

"""
    to_dot(io::IO, g::RDFGraph; label::AbstractString="RDF RDFGraph")

Write DOT representation of the graph to an IO stream.
"""
function to_dot(io::IO, g::RDFGraph; label::AbstractString="RDF RDFGraph")
    nsm = g.namespace_manager
    node_ids = Dict{Identifier, String}()
    counter = Ref(0)

    function get_id(term::Identifier)
        get!(node_ids, term) do
            counter[] += 1
            string("n", counter[])
        end
    end

    println(io, "digraph {")
    println(io, "  rankdir=LR;")
    println(io, "  label=\"", _dot_escape(label), "\";")
    println(io)

    # Collect triples first so we can emit nodes then edges
    tlist = collect(g)

    # Gather all unique terms
    all_terms = Set{Identifier}()
    for t in tlist
        push!(all_terms, t.subject)
        push!(all_terms, t.predicate)  # only used for edge labels
        push!(all_terms, t.object)
    end

    # Emit node declarations
    for term in all_terms
        term isa URIRef || term isa BNode || term isa Literal || continue
        # Skip predicates (URIRefs used only on edges) — they'll still get a
        # node id but we only declare subject/object nodes below.
    end

    # Emit nodes that actually appear as subjects or objects
    so_terms = Set{Identifier}()
    for t in tlist
        push!(so_terms, t.subject)
        push!(so_terms, t.object)
    end

    for term in so_terms
        nid = get_id(term)
        lbl = _dot_escape(_dot_node_label(nsm, term))
        if term isa BNode
            println(io, "  ", nid, " [shape=circle, label=\"\", width=0.3, style=filled, fillcolor=black];")
        elseif term isa Literal
            println(io, "  ", nid, " [shape=box, label=\"", lbl, "\"];")
        else  # URIRef
            println(io, "  ", nid, " [label=\"", lbl, "\"];")
        end
    end

    println(io)

    # Emit edges
    for t in tlist
        sid = get_id(t.subject)
        oid = get_id(t.object)
        elbl = _dot_escape(_compact_uri(nsm, t.predicate))
        println(io, "  ", sid, " -> ", oid, " [label=\"", elbl, "\"];")
    end

    println(io, "}")
end

"""
    to_dot(g::RDFGraph, filename::AbstractString; format::AbstractString="dot", label::AbstractString="RDF RDFGraph")

Write DOT to a file. If `format` is `"png"`, `"svg"`, or `"pdf"`, attempts to
run the `dot` command to generate the output (requires Graphviz installed).
"""
function to_dot(g::RDFGraph, filename::AbstractString;
                format::AbstractString="dot",
                label::AbstractString="RDF RDFGraph")
    if format == "dot"
        open(filename, "w") do f
            to_dot(f, g; label=label)
        end
    else
        # Generate via Graphviz dot command
        dotstr = to_dot(g; label=label)
        try
            run(pipeline(`dot -T$format`, stdin=IOBuffer(dotstr), stdout=filename))
        catch e
            error("Failed to run Graphviz `dot` command. Is Graphviz installed? ($e)")
        end
    end
    filename
end
