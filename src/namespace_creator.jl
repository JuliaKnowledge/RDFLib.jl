# ─── Namespace Creator — generate DefinedNamespace code from ontology ─

"""
    create_namespace(g::RDFGraph, ns_uri::AbstractString, name::AbstractString) -> String

Generate Julia source code for a `DefinedNamespace` from an ontology graph.
Scans all triples for URIRefs starting with `ns_uri` and extracts local names.

Returns a string of Julia code defining a `const` `DefinedNamespace`.
"""
function create_namespace(g::RDFGraph, ns_uri::AbstractString, name::AbstractString)
    terms = Set{String}()
    for t in triples(g)
        for node in (t.subject, t.predicate, t.object)
            if node isa URIRef && startswith(node.value, ns_uri)
                local_name = node.value[length(ns_uri)+1:end]
                if !isempty(local_name) && all(c -> isletter(c) || isdigit(c) || c == '_', local_name)
                    push!(terms, local_name)
                end
            end
        end
    end

    sorted_terms = sort(collect(terms))

    buf = IOBuffer()
    println(buf, "# Auto-generated namespace: $name")
    println(buf, "# URI: $ns_uri")
    println(buf)
    println(buf, "const $name = DefinedNamespace(")
    println(buf, "    \"$ns_uri\",")
    println(buf, "    Set([")
    for (i, term) in enumerate(sorted_terms)
        comma = i < length(sorted_terms) ? "," : ""
        println(buf, "        \"$term\"$comma")
    end
    println(buf, "    ])")
    println(buf, ")")

    String(take!(buf))
end
