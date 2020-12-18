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
end

"""
Represent an asset stored at an URL.
We try to always have online & local files for assets
If one gives an online resource, it will be downloaded, to host it locally.
"""
struct Asset
    media_type::Symbol
    # We try to always have online & local files for assets
    # If you only give an online resource, we will download it
    # to also be able to host it locally
    online_path::String
    local_path::String
    onload::Union{Nothing, JSCode}
end

"""
Encapsulates frontend dependencies. Can be used in the following way:

```Julia
const noUiSlider = Dependency(
    :noUiSlider,
    # js & css dependencies are supported
    [
        "https://cdn.jsdelivr.net/gh/leongersen/noUiSlider/distribute/nouislider.min.js",
        "https://cdn.jsdelivr.net/gh/leongersen/noUiSlider/distribute/nouislider.min.css"
    ]
)
# use the dependency on the frontend:
evaljs(session, js"\$(noUiSlider).some_function(...)")
```
jsrender will make sure that all dependencies get loaded.
"""
struct Dependency
    name::Symbol # The JS Module name that will get loaded
    assets::Vector{Asset}
    # The global -> Function name, JSCode -> the actual function code!
    functions::Dict{Symbol, JSCode}
end

"""
    UrlSerializer
Struct used to encode how an url is rendered
Fields:
```julia
# uses assetserver?
assetserver::Bool
# if assetserver == false, we move all assets into asset_folder
# for someone else to serve them!
asset_folder::Union{Nothing, String}

absolute::Bool
# Used to prepend if absolute == true
content_delivery_url::String
```
"""
struct UrlSerializer
    # uses assetserver?
    assetserver::Bool
    # if assetserver == false, we move all assets into asset_folder
    # for someone else to serve them!
    asset_folder::Union{Nothing, String}

    absolute::Bool
    # Used to prepend if absolute == true
    content_delivery_url::String
end

function UrlSerializer()
    proxy = JSSERVE_CONFIGURATION.content_delivery_url[]
    return UrlSerializer(
        true, nothing, proxy != "", proxy
    )
end

struct JSException <: Exception
    exception::String
    message::String
    stacktrace::Vector{String}
end

"""
Creates a Julia exception from data passed to us by the frondend!
"""
function JSException(js_data::AbstractDict)
    stacktrace = String[]
    if js_data["stacktrace"] !== nothing
        for line in split(js_data["stacktrace"], "\n")
            push!(stacktrace, replace(line, ASSET_URL_REGEX => replace_url))
        end
    end
    return JSException(js_data["exception"], js_data["message"], stacktrace)
end

function Base.show(io::IO, exception::JSException)
    println(io, "An exception was thrown in JS: $(exception.exception)")
    println(io, "Additional message: $(exception.message)")
    println(io, "Stack trace:")
    for line in exception.stacktrace
        println(io, "    ", line)
    end
end

"""
A web session with a user
"""
struct Session
    connection::Base.RefValue{WebSocket}
    # Bool -> if already registered with Frontend
    observables::Dict{String, Tuple{Bool, Observable}}
    message_queue::Vector{Dict{Symbol, Any}}
    dependencies::Set{Asset}
    on_document_load::Vector{JSCode}
    id::String
    js_fully_loaded::Channel{Bool}
    on_websocket_ready::Any
    url_serializer::UrlSerializer
    # Should be checkd on js_fully_loaded to see if an error occured
    init_error::Ref{Union{Nothing, JSException}}
    js_comm::Observable{Union{Nothing, Dict{String, Any}}}
    on_close::Observable{Bool}
end

struct Routes
    table::Vector{Pair{Any, Any}}
end


"""
The application one serves
"""
struct Application
    url::String
    port::Int
    sessions::Dict{String, Session}
    server_task::Ref{Task}
    server_connection::Ref{TCPServer}
    routes::Routes
    websocket_routes::Routes
end
