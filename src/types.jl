"""
The string part of JSCode.
"""
struct JSString
    source::String
end

"""
Javascript code that supports interpolation of Julia Objects.
Construction of JSCode via string macro:
```julia
jsc = js"console.log(\$(some_julia_variable))"
```
This will decompose into:
```julia
jsc.source == [JSString("console.log("), some_julia_variable, JSString("\"")]
```
"""
struct JSCode
    source::Vector{Union{JSString, Any}}
    file::String # location of the js string, a la "path/to/file:line"
end

JSCode(source) = JSCode(source, "")

"""
Represent an asset stored at an URL.
We try to always have online & local files for assets
"""
struct Asset
    name::Union{Nothing, String}
    es6module::Bool
    media_type::Symbol
    # We try to always have online & local files for assets
    # If you only give an online resource, we will download it
    # to also be able to host it locally
    online_path::String
    local_path::Union{String, Path}
    last_bundled::Base.RefValue{Union{Nothing, Dates.DateTime}}
end

struct JSException <: Exception
    exception::String
    message::String
    stacktrace::Vector{String}
end

function js_to_local_stacktrace(asset_server, matched_url)
    return matched_url
end

function Base.show(io::IO, exception::JSException)
    println(io, "An exception was thrown in JS: $(exception.exception)")
    println(io, "Additional message: $(exception.message)")
    println(io, "Stack trace:")
    for line in exception.stacktrace
        println(io, "    ", line)
    end
end

abstract type FrontendConnection end
abstract type AbstractAssetServer end

mutable struct SubConnection <: FrontendConnection
    connection::FrontendConnection
    isopen::Bool
end

struct SerializedMessage
    bytes::Vector{UInt8}
end

@enum SessionStatus UNINITIALIZED DISPLAYED OPEN CLOSED

"""
A web session with a user
"""
mutable struct Session{Connection <: FrontendConnection}
    status::SessionStatus
    parent::Union{Session, Nothing}
    children::Dict{String, Session{SubConnection}}
    id::String
    # The connection to the JS frontend.
    # Currently can be IJuliaConnection, WebsocketConnection, PlutoConnection, NoConnection
    connection::Connection
    # The way we serve any file asset
    asset_server::AbstractAssetServer
    message_queue::Vector{SerializedMessage}
    # Code that gets evalued last after all other messages, when session gets connected
    on_document_load::Vector{JSCode}
    connection_ready::Channel{Bool}
    on_connection_ready::Function
    # Should be checkd on connection_ready to see if an error occured
    init_error::Ref{Union{Nothing, JSException}}
    js_comm::Observable{Union{Nothing, Dict{String, Any}}}
    on_close::Observable{Bool}
    deregister_callbacks::Vector{Observables.ObserverFunction}
    session_objects::Dict{String, Any}
    # For rendering Hyperscript.Node, and giving them a unique id inside the session
    dom_uuid_counter::Int
    ignore_message::RefValue{Function}
    imports::Set{Asset}
    title::String
    compression_enabled::Bool

    function Session(
            parent::Union{Session, Nothing},
            children::Dict{String, Session{SubConnection}},
            id::String,
            connection::Connection,
            asset_server::AbstractAssetServer,
            message_queue::Vector{SerializedMessage},
            on_document_load::Vector{JSCode},
            connection_ready::Channel{Bool},
            on_connection_ready::Function,
            init_error::Ref{Union{Nothing, JSException}},
            js_comm::Observable{Union{Nothing, Dict{String, Any}}},
            on_close::Observable{Bool},
            deregister_callbacks::Vector{Observables.ObserverFunction},
            session_objects::Dict{String, Any},
            dom_uuid_counter::Int,
            ignore_message::RefValue{Function},
            imports::Set{Asset},
            title::String,
            compression_enabled::Bool,
        ) where {Connection}
        session = new{Connection}(
            UNINITIALIZED,
            parent,
            children,
            id,
            connection,
            asset_server,
            message_queue,
            on_document_load,
            connection_ready,
            on_connection_ready,
            init_error,
            js_comm,
            on_close,
            deregister_callbacks,
            session_objects,
            dom_uuid_counter,
            ignore_message,
            imports,
            title,
            compression_enabled,
        )
        finalizer(session) do s
            # Closing may yield, so we need to async it
            # Is that ok?
            # TODO, implement free(s), which only does finalizer save things
            @async close(s)
        end
        return session
    end
end

struct BinaryAsset
    data::Vector{UInt8}
    mime::String
end
BinaryAsset(session::Session, @nospecialize(data)) = BinaryAsset(SerializedMessage(session, data).bytes, "application/octet-stream")

"""
Creates a Julia exception from data passed to us by the frondend!
"""
function JSException(session::Session, js_data::AbstractDict)
    stacktrace = String[]
    if js_data["stacktrace"] != "nothing"
        for line in split(js_data["stacktrace"], "\n")
            push!(stacktrace, js_to_local_stacktrace(session.asset_server, line))
        end
    end
    return JSException(js_data["exception"], js_data["message"], stacktrace)
end

function Session(connection=default_connection();
                id=string(uuid4()),
                asset_server=default_asset_server(),
                message_queue=SerializedMessage[],
                on_document_load=JSCode[],
                connection_ready=Channel{Bool}(1),
                on_connection_ready=init_session,
                init_error=Ref{Union{Nothing, JSException}}(nothing),
                js_comm=Observable{Union{Nothing, Dict{String, Any}}}(nothing),
                on_close=Observable(false),
                deregister_callbacks=Observables.ObserverFunction[],
                session_objects=Dict{String, Any}(),
                imports=Set{Asset}(),
                title="JSServe App",
                compression_enabled=default_compression())

    return Session(
        nothing,
        Dict{String, Session{SubConnection}}(),
        id,
        connection,
        asset_server,
        message_queue,
        on_document_load,
        connection_ready,
        on_connection_ready,
        init_error,
        js_comm,
        on_close,
        deregister_callbacks,
        session_objects,
        0,
        RefValue{Function}(x-> false),
        imports,
        title,
        compression_enabled,
    )
end

function Session(parent::Session;
            asset_server=parent.asset_server,
            on_connection_ready=init_session, title=parent.title)

    root = root_session(parent)
    connection = SubConnection(root)
    session = Session(connection; asset_server=asset_server, on_connection_ready, title=title)
    session.parent = root
    root.children[session.id] = session
    return session
end

mutable struct App
    handler::Function
    session::Base.RefValue{Union{Session, Nothing}}
    title::String
    function App(handler::Function;
            title::AbstractString="JSServe App")

        session = Base.RefValue{Union{Session, Nothing}}(nothing)
        if hasmethod(handler, Tuple{Session, HTTP.Request})
            app = new(handler, session, title)
        elseif hasmethod(handler, Tuple{Session})
            app = new((session, request) -> handler(session), session, title)
        elseif hasmethod(handler, Tuple{HTTP.Request})
            app = new((session, request) -> handler(request), session, title)
        elseif hasmethod(handler, Tuple{})
            app = new((session, request) -> handler(), session, title)
        else
            error("""
            Handler function must have the following signature:
                handler() -> DOM
                handler(session::Session) -> DOM
                handler(request::Request) -> DOM
                handler(session, request) -> DOM
            """)
        end
        finalizer(close, app)
        return app
    end
    function App(dom_object; title="JSServe App")
        session = Base.RefValue{Union{Session,Nothing}}(nothing)
        app = new((s, r) -> dom_object, session, title)
        finalizer(close, app)
        return app
    end
end

struct Routes
    routes::Dict{String, App}
end

Routes() = Routes(Dict{String, App}())

Base.setindex!(routes::Routes, app::App, key::String) = (routes.routes[key] = app)
