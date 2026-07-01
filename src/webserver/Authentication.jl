import .Throttled

"""
The name of the auth cookie, scoped by the server's port.

Cookies are scoped by host + name + path — **the port is not part of a cookie's scope**
(RFC 6265). So multiple Pluto servers on the same host (e.g. several `plutospace` workspaces
on `localhost:1234`, `:1235`, …) would all set a cookie named `secret` for `localhost` and
*clobber each other*: launching a second server logs the first one out of its own browser tab,
turning every cookie-authenticated request (`./api/v1/notebooks`, `./edit?id=…`, the editor
WebSocket) into a 403. Putting the port in the cookie *name* gives each server its own cookie,
so any number of workspaces can run side by side.
"""
secret_cookie_name(session::ServerSession) = "pluto_secret_$(something(session.options.server.port, 0))"

"""
Return whether the `request` was authenticated in one of two ways:
1. the session's `secret` was included in the URL as a search parameter, or
2. the session's `secret` was included in a cookie.
"""
function is_authenticated(session::ServerSession, request::HTTP.Request)
    (
        secret_in_url = try
            uri = HTTP.URI(request.target)
            query = HTTP.queryparams(uri)
            get(query, "secret", "") == session.secret
        catch e
            @warn "Failed to authenticate request using URL" exception = (e, catch_backtrace())
            false
        end
    ) || (
        secret_in_cookie = try
            cookies = HTTP.cookies(request)
            cookie_name = secret_cookie_name(session)
            any(cookies) do cookie
                cookie.name == cookie_name && cookie.value == session.secret
            end
        catch e
            @warn "Failed to authenticate request using cookies" exception = (e, catch_backtrace())
            false
        end
    )
    # that ) || ( kind of looks like Krabs from spongebob
end

# Function to log the url with secret on the Julia CLI when a request comes to the server without the secret. Executes at most once every 5 seconds
const log_secret_throttled = Throttled.simple_leading_throttle(5) do session::ServerSession, request::HTTP.Request
    host = HTTP.header(request, "Host")
    target = request.target
    url = Text(string(HTTP.URI(HTTP.URI("http://$host/"); query=Dict("secret" => session.secret))))
    @info("No longer authenticated? Visit this URL to continue:", url)
end


function add_set_secret_cookie!(session::ServerSession, response::HTTP.Response)
    HTTP.setheader(response, "Set-Cookie" => "$(secret_cookie_name(session))=$(session.secret); Path=/; SameSite=Strict; HttpOnly")
    response
end

"""
    origin_matches_host(request) -> Bool

Cross-origin defense for requests that carry ambient credentials (the secret cookie).

`SameSite=Strict` is NOT enough on its own here: a cookie's scope is host + name + path —
**the port is not part of it** — and browsers treat every `localhost:<port>` as the *same site*.
So a page served from any *other* local port (a second dev server, a docs preview, a compromised
dependency's dev server) is same-site with this one, and the browser will happily attach our
`pluto_secret_<port>` cookie to a request it initiates at us. That turns two of the fork's
additions into remote code execution: the `/terminal` WebSocket (an interactive shell) and the
`POST /api/v1/file/*` endpoints (arbitrary-path file writes).

The robust signal a browser cannot forge from another origin is the `Origin` header: it always
reflects the page that initiated the request, and script cannot set it. So:

  • No `Origin` header → allow. Non-browser clients (the `pluto-collab` CLI, `curl`, native
    WebSocket libraries) don't send one, and they are not a CSRF vector — they must still present
    the secret. A browser NEVER omits `Origin` on a WebSocket handshake or a cross-origin fetch.
  • `Origin` present → its authority (host:port) must equal the request's `Host`. The legitimate
    same-origin frontend always matches; a cross-origin attacker page never can.

Fails closed (unparseable Origin, or absent Host → reject). This is a backstop that holds even
in the dangerous `require_secret_for_access=false` Binder config, where the same-origin frontend
still matches but any attacker origin is refused.
"""
function origin_matches_host(request::HTTP.Request)::Bool
    origin = HTTP.header(request, "Origin", "")
    isempty(origin) && return true
    host = HTTP.header(request, "Host", "")
    isempty(host) && return false
    return try
        o = HTTP.URI(origin)
        authority = isempty(o.port) ? o.host : "$(o.host):$(o.port)"
        authority == host
    catch
        false
    end
end

"HTTP methods that (by spec) don't change server state — the browser sends them freely, so they carry no CSRF risk on their own. Anything else must pass [`origin_matches_host`]."
is_safe_http_method(request::HTTP.Request)::Bool = uppercase(request.method) in ("GET", "HEAD", "OPTIONS")

# too many layers i know
"""
Generate a middleware (i.e. a function `HTTP.Handler -> HTTP.Handler`) that stores the `session` in every `request`'s context.
"""
function create_session_context_middleware(session::ServerSession)
    function session_context_middleware(handler::Function)::Function
        function(request::HTTP.Request)
            request.context[:pluto_session] = session
            handler(request)
        end
    end
end


session_from_context(request::HTTP.Request) = request.context[:pluto_session]::ServerSession


function auth_required(session::ServerSession, request::HTTP.Request)
    path = HTTP.URI(request.target).path
    ext = splitext(path)[2]
    security = session.options.security

    if path ∈ ("/ping", "/possible_binder_token_please") || ext ∈ (".ico", ".js", ".css", ".png", ".gif", ".svg", ".ico", ".woff2", ".woff", ".ttf", ".eot", ".otf", ".json", ".map")
        false
    elseif path ∈ ("", "/")
        # / does not need security.require_secret_for_open_links, because this is how we handle the configuration where:
        #    require_secret_for_open_links == true
        #    require_secret_for_access == false
        # 
        # This means that access to all 'risky' endpoints is restricted to authenticated requests (to prevent CSRF), but we allow an unauthenticated request to visit the `/` page and acquire the cookie (see `add_set_secret_cookie!`).
        # 
        # (By default, `require_secret_for_access` (and `require_secret_for_open_links`) is `true`.)
        security.require_secret_for_access
    else
        security.require_secret_for_access || 
        security.require_secret_for_open_links
    end
end


"""
    auth_middleware(f::HTTP.Handler) -> HTTP.Handler

Returns an `HTTP.Handler` (i.e. a function `HTTP.Request → HTTP.Response`) which does three things:
1. Check whether the request is authenticated (by calling `is_authenticated`), if not, return a 403 error.
2. Call your `f(request)` to create the response message.
3. Add a `Set-Cookie` header to the response with the session's `secret`.

This is for HTTP requests, the authentication mechanism for WebSockets is separate.
"""
function auth_middleware(handler)
    return function (request::HTTP.Request)
        session = session_from_context(request)
        required = auth_required(session, request)

        # CSRF backstop: a state-changing request that carries a mismatched browser Origin is a
        # cross-site forgery riding the ambient cookie (see origin_matches_host). Refuse it before
        # it can write a file / open a workspace / shut the server down — even in no-secret Binder
        # mode. Safe methods and non-browser clients (no Origin) are unaffected.
        if !is_safe_http_method(request) && !origin_matches_host(request)
            return error_response(403, "Cross-origin request blocked", "This request was refused because its <em>Origin</em> does not match the server. If you are a developer calling this API, connect from the same origin or omit the browser Origin header.")
        end

        if !required || is_authenticated(session, request)
            response = handler(request)
            if !required
                filter!(p -> p[1] != "Access-Control-Allow-Origin", response.headers)
                HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")
            end
            if required || HTTP.URI(request.target).path ∈ ("", "/")
                add_set_secret_cookie!(session, response)
            end
            response
        else
            log_secret_throttled(session, request)
            error_response(403, "Not yet authenticated", "<b>Open the link that was printed in the terminal where you launched Pluto.</b> It includes a <em>secret</em>, which is needed to access this server.<br><br>If you are running the server yourself and want to change this configuration, have a look at the keyword arguments to <em>Pluto.run</em>. <br><br>Please <a href='https://github.com/fonsp/Pluto.jl/issues'>report this error</a> if you did not expect it!")
        end
    end
end
