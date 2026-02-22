# ─── RDFS/OWL Schema DOT Visualization ──────────────────────────────

"""
    rdfs2dot(g::RDFGraph; label::AbstractString="RDFS Schema") -> String

Generate a Graphviz DOT string for RDFS/OWL schema visualization.

Classes are shown as boxes, properties as labeled edges between domain and range,
and `rdfs:subClassOf` relationships as dashed edges.

# Example
```julia
dot = rdfs2dot(g; label="My Ontology")
open("schema.dot", "w") do f
    print(f, dot)
end
```
"""
function rdfs2dot(g::RDFGraph; label::AbstractString="RDFS Schema")
    buf = IOBuffer()
    rdfs2dot(buf, g; label=label)
    String(take!(buf))
end

"""
    rdfs2dot(io::IO, g::RDFGraph; label::AbstractString="RDFS Schema")

Write RDFS/OWL schema DOT to an IO stream.
"""
function rdfs2dot(io::IO, g::RDFGraph; label::AbstractString="RDFS Schema")
    nsm = g.namespace_manager

    # Collect classes (rdfs:Class and owl:Class instances)
    classes = Set{URIRef}()
    owl_classes = Set{URIRef}()
    for t in triples(g, (nothing, RDF.type, RDFS.Class))
        t.subject isa URIRef && push!(classes, t.subject)
    end
    for t in triples(g, (nothing, RDF.type, OWL.Class))
        t.subject isa URIRef && push!(owl_classes, t.subject)
    end
    all_classes = union(classes, owl_classes)

    # Collect rdfs:subClassOf relationships
    subclass_edges = Tuple{URIRef,URIRef}[]
    for t in triples(g, (nothing, RDFS.subClassOf, nothing))
        t.subject isa URIRef && t.object isa URIRef &&
            push!(subclass_edges, (t.subject, t.object))
    end

    # Collect properties with domain/range
    prop_uris = Set{URIRef}()
    for t in triples(g, (nothing, RDF.type, OWL.ObjectProperty))
        t.subject isa URIRef && push!(prop_uris, t.subject)
    end
    for t in triples(g, (nothing, RDF.type, OWL.DatatypeProperty))
        t.subject isa URIRef && push!(prop_uris, t.subject)
    end
    # Also pick up any URI that has rdfs:domain or rdfs:range
    for t in triples(g, (nothing, RDFS.domain, nothing))
        t.subject isa URIRef && push!(prop_uris, t.subject)
    end
    for t in triples(g, (nothing, RDFS.range, nothing))
        t.subject isa URIRef && push!(prop_uris, t.subject)
    end

    # Build domain/range maps
    domains = Dict{URIRef,URIRef}()
    ranges  = Dict{URIRef,URIRef}()
    for t in triples(g, (nothing, RDFS.domain, nothing))
        t.subject isa URIRef && t.object isa URIRef &&
            (domains[t.subject] = t.object)
    end
    for t in triples(g, (nothing, RDFS.range, nothing))
        t.subject isa URIRef && t.object isa URIRef &&
            (ranges[t.subject] = t.object)
    end

    # Collect rdfs:label for display names
    labels = Dict{URIRef,String}()
    for t in triples(g, (nothing, RDFS.label, nothing))
        t.subject isa URIRef && t.object isa Literal &&
            (labels[t.subject] = t.object.lexical)
    end

    # Node IDs
    node_ids = Dict{URIRef,String}()
    counter = Ref(0)
    function get_id(uri::URIRef)
        get!(node_ids, uri) do
            counter[] += 1
            string("n", counter[])
        end
    end

    display_name(uri::URIRef) = get(labels, uri, _compact_uri(nsm, uri))

    # Ensure classes referenced only in domain/range also get nodes
    for (_, cls) in domains
        push!(all_classes, cls)
    end
    for (_, cls) in ranges
        push!(all_classes, cls)
    end

    println(io, "digraph {")
    println(io, "  rankdir=BT;")
    println(io, "  label=\"", _dot_escape(label), "\";")
    println(io, "  fontsize=14;")
    println(io)

    # Emit class nodes
    for cls in all_classes
        nid = get_id(cls)
        lbl = _dot_escape(display_name(cls))
        if cls in owl_classes
            println(io, "  ", nid, " [shape=box, style=\"filled\", fillcolor=\"#E8F4FD\", label=\"", lbl, "\"];")
        else
            println(io, "  ", nid, " [shape=box, label=\"", lbl, "\"];")
        end
    end

    println(io)

    # Emit subClassOf edges (dashed)
    for (sub, sup) in subclass_edges
        push!(all_classes, sub)
        push!(all_classes, sup)
        sid = get_id(sub)
        pid = get_id(sup)
        println(io, "  ", sid, " -> ", pid, " [style=dashed, label=\"subClassOf\"];")
    end

    # Emit property edges (domain -> range)
    for prop in prop_uris
        dom = get(domains, prop, nothing)
        rng = get(ranges, prop, nothing)
        isnothing(dom) && isnothing(rng) && continue
        plbl = _dot_escape(display_name(prop))
        if !isnothing(dom) && !isnothing(rng)
            println(io, "  ", get_id(dom), " -> ", get_id(rng), " [label=\"", plbl, "\"];")
        elseif !isnothing(dom)
            # Property with domain only — show as self-loop
            println(io, "  ", get_id(dom), " -> ", get_id(dom), " [label=\"", plbl, "\"];")
        end
    end

    println(io, "}")
end
