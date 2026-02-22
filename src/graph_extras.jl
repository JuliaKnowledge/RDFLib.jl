# ─── Additional Graph methods ───────────────────────────────────────

"""
    transitive_objects(g::RDFGraph, subject::Node, property::URIRef) -> Set{Identifier}

Follow a property transitively to collect all reachable objects.
Returns all nodes reachable from `subject` via `property`, including `subject` itself.
"""
function transitive_objects(g::RDFGraph, subject::Node, property::URIRef)::Set{Identifier}
    result = Set{Identifier}()
    push!(result, subject)
    queue = Identifier[subject]
    while !isempty(queue)
        current = popfirst!(queue)
        current_node = current isa Node ? current : nothing
        isnothing(current_node) && continue
        for obj in objects(g, current_node, property)
            if obj ∉ result
                push!(result, obj)
                push!(queue, obj)
            end
        end
    end
    result
end

"""
    transitive_subjects(g::RDFGraph, object::Identifier, property::URIRef) -> Set{Node}

Follow a property transitively backwards to collect all reachable subjects.
Returns all nodes that can reach `object` via `property`, including `object` if it is a Node.
"""
function transitive_subjects(g::RDFGraph, object::Identifier, property::URIRef)::Set{Node}
    result = Set{Node}()
    if object isa Node
        push!(result, object)
    end
    queue = Identifier[object]
    while !isempty(queue)
        current = popfirst!(queue)
        for subj in subjects(g, property, current)
            if subj ∉ result
                push!(result, subj)
                push!(queue, subj)
            end
        end
    end
    result
end

"""
    all_nodes(g::RDFGraph) -> Set{Identifier}

Get all unique nodes (subjects and objects) in the graph.
"""
function all_nodes(g::RDFGraph)::Set{Identifier}
    result = Set{Identifier}()
    for t in g
        push!(result, t.subject)
        push!(result, t.object)
    end
    result
end

"""
    triples_choices(g::RDFGraph; subjects, predicates, objects) -> Vector{Triple}

Query with alternative values in any position. Returns triples matching
any combination of the given alternatives. `nothing` means wildcard.
"""
function triples_choices(g::RDFGraph;
    subjects::Union{Vector, Nothing}=nothing,
    predicates::Union{Vector, Nothing}=nothing,
    objects::Union{Vector, Nothing}=nothing)::Vector{Triple}
    result = Set{Triple}()
    ss = isnothing(subjects) ? [nothing] : subjects
    ps = isnothing(predicates) ? [nothing] : predicates
    os = isnothing(objects) ? [nothing] : objects
    for s in ss, p in ps, o in os
        for t in triples(g, (s, p, o))
            push!(result, t)
        end
    end
    collect(result)
end

"""
    skolemize(g::RDFGraph; authority) -> RDFGraph

Convert blank nodes to skolem URIs. Returns a new graph with each BNode
replaced by `URIRef(authority * bnode.id)`.
"""
function skolemize(g::RDFGraph; authority::AbstractString="https://rdflib.github.io/.well-known/genid/")::RDFGraph
    result = RDFGraph()
    _sk(node::BNode) = URIRef(authority * node.id)
    _sk(node) = node
    for t in g
        add!(result, Triple(_sk(t.subject), t.predicate, _sk(t.object)))
    end
    result
end

"""
    de_skolemize(g::RDFGraph; authority) -> RDFGraph

Convert skolem URIs back to blank nodes. Inverse of `skolemize`.
"""
function de_skolemize(g::RDFGraph; authority::AbstractString="https://rdflib.github.io/.well-known/genid/")::RDFGraph
    result = RDFGraph()
    function _desk(node)
        if node isa URIRef && startswith(node.value, authority)
            return BNode(node.value[length(authority)+1:end])
        end
        node
    end
    for t in g
        s = _desk(t.subject)
        o = _desk(t.object)
        add!(result, Triple(s, t.predicate, o))
    end
    result
end

"""
    parse_into!(g::RDFGraph, data::AbstractString, fmt::SerializationFormat)

Parse RDF data into the graph (convenience wrapper). Returns the graph.
"""
function parse_into!(g::RDFGraph, data::AbstractString, fmt::SerializationFormat)
    parse_rdf!(g, data, fmt)
    g
end

"""
    graph_n3(g::RDFGraph) -> String

Serialize the graph to Turtle (N3 subset) format string.
"""
function graph_n3(g::RDFGraph)::String
    serialize(g, TurtleFormat())
end
