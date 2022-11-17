module JSServe

import Sockets
using Sockets: send

using Dates
using UUIDs
using Hyperscript
using Observables
using Hyperscript: Node, children, tag
using Markdown
using HTTP
using Deno_jll

using Base64
using MsgPack
using WidgetsBase
using WidgetsBase: vertical, horizontal
using SHA
using Tables
using Colors
using LinearAlgebra
using CodecZlib
using RelocatableFolders: @path, Path, getroot
using URIs

using Base: RefValue

include("types.jl")
include("HTTPServer/HTTPServer.jl")
include("js_source.jl")
include("session.jl")
include("jsrender.jl")
include("observables.jl")
include("asset-servers/assets.jl")
include("connection/connection.jl")
include("util.jl")
include("widgets.jl")
include("hyperscript_integration.jl")
include("display.jl")
include("markdown_integration.jl")
include("serialization.jl")
include("offline.jl")

function has_html_display()
    for display in Base.Multimedia.displays
        # Ugh, why would textdisplay say it supports HTML??
        display isa TextDisplay && continue
        displayable(display, MIME"text/html"()) && return true
    end
    return false
end

# Core functionality
export Page, Session, App, DOM, @js_str
export Slider, Button

import .HTTPServer: browser_display, configure_server!
export browser_display, configure_server!

end # module
