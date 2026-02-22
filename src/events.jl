# ─── Event / Observer System ────────────────────────────────────────
# Simple event system for graph change notifications.

# Event types
abstract type RDFEvent end

struct TripleAdded <: RDFEvent
    triple::RDFLib.Triple
end

struct TripleRemoved <: RDFEvent
    triple::RDFLib.Triple
end

struct GraphCleared <: RDFEvent end

# Event dispatcher
mutable struct EventDispatcher
    listeners::Dict{Type{<:RDFEvent}, Vector{Function}}
end

EventDispatcher() = EventDispatcher(Dict{Type{<:RDFEvent}, Vector{Function}}())

"""
    on!(dispatcher, event_type, callback)

Register a callback for the given event type.
"""
function on!(dispatcher::EventDispatcher, event_type::Type{<:RDFEvent}, callback::Function)
    if !haskey(dispatcher.listeners, event_type)
        dispatcher.listeners[event_type] = Function[]
    end
    push!(dispatcher.listeners[event_type], callback)
    dispatcher
end

"""
    off!(dispatcher, event_type, callback)

Unregister a callback for the given event type.
"""
function off!(dispatcher::EventDispatcher, event_type::Type{<:RDFEvent}, callback::Function)
    if haskey(dispatcher.listeners, event_type)
        filter!(f -> f !== callback, dispatcher.listeners[event_type])
    end
    dispatcher
end

"""
    emit!(dispatcher, event)

Fire all registered callbacks for the event's type.
"""
function emit!(dispatcher::EventDispatcher, event::RDFEvent)
    T = typeof(event)
    if haskey(dispatcher.listeners, T)
        for cb in dispatcher.listeners[T]
            cb(event)
        end
    end
end

# Observable graph wrapper
"""
    ObservableGraph(g::RDFGraph)
    ObservableGraph()

A graph wrapper that emits `TripleAdded` / `TripleRemoved` events.
Subscribe with `on!(og.dispatcher, EventType, callback)`.
"""
mutable struct ObservableGraph
    graph::RDFLib.RDFGraph
    dispatcher::EventDispatcher
end

ObservableGraph(g::RDFLib.RDFGraph) = ObservableGraph(g, EventDispatcher())
ObservableGraph() = ObservableGraph(RDFLib.RDFGraph())

function RDFLib.add!(og::ObservableGraph, t::RDFLib.Triple)
    RDFLib.add!(og.graph, t)
    emit!(og.dispatcher, TripleAdded(t))
    og
end

function RDFLib.remove!(og::ObservableGraph, pattern)
    for t in collect(RDFLib.triples(og.graph, pattern))
        emit!(og.dispatcher, TripleRemoved(t))
    end
    RDFLib.remove!(og.graph, pattern)
    og
end

RDFLib.triples(og::ObservableGraph, pattern=(nothing, nothing, nothing)) = RDFLib.triples(og.graph, pattern)
Base.length(og::ObservableGraph) = length(og.graph)
Base.isempty(og::ObservableGraph) = isempty(og.graph)
