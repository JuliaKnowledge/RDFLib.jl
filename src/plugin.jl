# ─── Plugin System ──────────────────────────────────────────────────
# Dynamic registration of parsers, serializers, and stores.

const _PARSER_REGISTRY = Dict{String, Function}()
const _SERIALIZER_REGISTRY = Dict{String, Function}()
const _STORE_REGISTRY = Dict{String, Type}()

"""
    register_parser!(mime_type, parse_fn)

Register a parser function for a MIME type.
`parse_fn` should have signature `(g::RDFGraph, data::AbstractString)`.
"""
function register_parser!(mime_type::AbstractString, parse_fn::Function)
    _PARSER_REGISTRY[String(mime_type)] = parse_fn
end

"""
    register_serializer!(mime_type, serialize_fn)

Register a serializer function for a MIME type.
`serialize_fn` should have signature `(g::RDFGraph) -> String`.
"""
function register_serializer!(mime_type::AbstractString, serialize_fn::Function)
    _SERIALIZER_REGISTRY[String(mime_type)] = serialize_fn
end

"""
    register_store!(name, store_type)

Register a store type by name.
"""
function register_store!(name::AbstractString, store_type::Type)
    _STORE_REGISTRY[String(name)] = store_type
end

"""
    get_parser(mime_type) -> Union{Function, Nothing}
"""
get_parser(mime_type::AbstractString) = get(_PARSER_REGISTRY, String(mime_type), nothing)

"""
    get_serializer(mime_type) -> Union{Function, Nothing}
"""
get_serializer(mime_type::AbstractString) = get(_SERIALIZER_REGISTRY, String(mime_type), nothing)

"""
    get_store(name) -> Union{Type, Nothing}
"""
get_store(name::AbstractString) = get(_STORE_REGISTRY, String(name), nothing)

"""
    list_parsers() -> Vector{String}
"""
list_parsers() = sort(collect(keys(_PARSER_REGISTRY)))

"""
    list_serializers() -> Vector{String}
"""
list_serializers() = sort(collect(keys(_SERIALIZER_REGISTRY)))

"""
    list_stores() -> Vector{String}
"""
list_stores() = sort(collect(keys(_STORE_REGISTRY)))

"""
    unregister_parser!(mime_type)

Remove a registered parser.
"""
function unregister_parser!(mime_type::AbstractString)
    delete!(_PARSER_REGISTRY, String(mime_type))
end

"""
    unregister_serializer!(mime_type)

Remove a registered serializer.
"""
function unregister_serializer!(mime_type::AbstractString)
    delete!(_SERIALIZER_REGISTRY, String(mime_type))
end

"""
    unregister_store!(name)

Remove a registered store.
"""
function unregister_store!(name::AbstractString)
    delete!(_STORE_REGISTRY, String(name))
end

"""
    _register_builtins!()

Register built-in parsers, serializers, and stores.
"""
function _register_builtins!()
    register_parser!("application/n-triples", (g, data) -> RDFLib.parse_rdf!(g, data, RDFLib.NTriplesFormat()))
    register_parser!("text/turtle", (g, data) -> RDFLib.parse_rdf!(g, data, RDFLib.TurtleFormat()))

    register_serializer!("application/n-triples", g -> RDFLib.serialize(g, RDFLib.NTriplesFormat()))
    register_serializer!("text/turtle", g -> RDFLib.serialize(g, RDFLib.TurtleFormat()))

    register_store!("memory", RDFLib.MemoryStore)
end
