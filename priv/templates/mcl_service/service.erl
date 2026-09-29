{{=<% %>=}}%% @doc The mcl_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.
%%
%% IT ANNOUNCES NOTHING AND ASKS FOR NOTHING, on purpose. A service that does
%% nothing yet has no capability to offer and needs no authority from the realm.
%% Advertising a capability before it exists puts a lie on the mesh that another
%% service can find and call. Both lists grow when the thing they name exists,
%% and a generated test fails when they change, so growing them is a deliberate
%% act rather than a comment someone forgot.
-module(<%name%>_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
<%#store%>
%% ==========================================================================
%% AND THE STORE THIS SERVICE OWNS
%% ==========================================================================
%%
%% Generated because this service was scaffolded with `store=1'. NOT an mcl_om
%% callback: mcl_om opens no store since 0.35.0. <%name%>_app reads it and opens
%% the store in its own start/2 before mcl_om:boot/1, with reckon_db, evoq and
%% reckon_evoq declared by this service in rebar.config and its app.src.
%%
%% ⚠ ONE MAP, NOT THE OLD `store_id/0' AND `data_dir/0' CALLBACKS. mcl_om 0.35
%% warns at every boot about a service module exporting those two together,
%% because that is how a service built for the old contract looks, and a false
%% warning teaches everyone to ignore the true one.
%%
%% ⚠ `config/sys.config.src' MUST CARRY THE `evoq' BLOCK, which is why it was
%% generated with one. The per-store evoq subscription reads the global log, and
%% that crashes on `{not_configured, event_store_adapter}' without it. evoq starts
%% as a release-boot application before any service's `start/2' runs, so nothing
%% can inject it later. A sibling put two of three fleet nodes into a boot-crash
%% loop this exact way.
-export([event_store/0]).
<%/store%>

info() ->
    #{name => <<"<%repo%>">>,
      version => <<"0.1.0">>,
      description => <<"<%desc%>">>}.

start(_Opts) -> <%name%>_sup:start_link().

stop(_State) -> ok.

%% Green once the supervision tree is up. Replace this with a real probe of
%% whatever this service needs in order to do its job. A dark mesh is usually NOT
%% a health failure: decide that deliberately rather than by default.
health() -> ok.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. Other services find this one by these
%% names, so each entry is a promise that something answers.
capabilities() -> [].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"<%repo%>">>,
      actions => [],
      resources => [],
      ttl_days => 30}.
<%#store%>

%% ==========================================================================
%% The store
%% ==========================================================================

%% @doc The reckon-db store this service owns, as <%name%>_app opens it.
%%
%% `id': ⚠ IT IS NAMED IN TWO PLACES, here and in the `evoq' block of
%% `config/sys.config.src', and nothing makes them agree by itself. Disagreeing
%% opens one store and addresses another. A generated test compares the two.
%%
%% `dir': where it lives on disk (the store itself at <dir>/<id>/). ⚠ DEFAULTS TO
%% A PATH INSIDE THE CONTAINER AND MUST NOT STAY THERE ON A NODE. The fleet keeps
%% application data on its `/bulk' drives and boots from a small eMMC, so
%% `deploy/docker-compose.yml' mounts a volume and sets MCL_DATA_DIR. A container
%% without the mount loses its record on every recreate.
%%
%% `indexes': the secondary indexes the store maintains, e.g. [tags, event_type,
%% {payload, <<"plate">>}], declared when it opens (a store already running
%% ignores a second declaration). None until a query needs one.
%%
%% `mode': `single', one node's store; `cluster' makes reckon-db form a Ra cluster
%% across every node that opens the same id.
%%
%% `integrity': `disabled', or `#{enabled => true, key_source => {env_var, Name}}'
%% for per-store HMAC tamper-resistance. The store refuses to start when integrity
%% is enabled and the key cannot be loaded, so provision the key first.
-spec event_store() -> #{id := atom(), dir := string(), indexes := [term()],
                         mode := single | cluster, integrity := disabled | map()}.
event_store() ->
    #{id => <%name%>_store,
      dir => chosen(os:getenv("MCL_DATA_DIR")),
      indexes => [],
      mode => single,
      integrity => disabled}.

chosen(false) -> "/tmp/<%name%>";
chosen("") -> "/tmp/<%name%>";
chosen(Path) -> Path.
<%/store%>
