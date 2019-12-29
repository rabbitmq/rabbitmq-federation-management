%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2020 Pivotal Software, Inc.  All rights reserved.
%%

-module(federation_mgmt_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_mgmt_test.hrl").

-compile(export_all).

all() ->
    [
      {group, non_parallel_tests}
    ].

groups() ->
    [
     {non_parallel_tests, [], [
                               federation_links,
                               federation_down_links,
                               restart_link
                              ]}
    ].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------
init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    inets:start(),
    Config1 = rabbit_ct_helpers:set_config(Config, [
                                                    {rmq_nodename_suffix, ?MODULE}
                                                   ]),
    rabbit_ct_helpers:run_setup_steps(Config1,
                                      rabbit_ct_broker_helpers:setup_steps() ++
                                          rabbit_ct_client_helpers:setup_steps() ++
                                          [fun setup_federation/1]).
end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config,
                                         rabbit_ct_client_helpers:teardown_steps() ++
                                             rabbit_ct_broker_helpers:teardown_steps()).

setup_federation(Config) ->
    set_policy(Config),
    Port = amqp_port(Config, 0),
    Uri = lists:flatten(io_lib:format("amqp://myuser:myuser@localhost:~p", [Port])),
    rabbit_ct_broker_helpers:set_parameter(
      Config, 0, <<"federation-upstream">>, <<"broken-bunny">>,
      [{<<"uri">>, list_to_binary(Uri)},
       {<<"reconnect-delay">>, 600000}]),
    rabbit_ct_broker_helpers:set_parameter(
      Config, 0, <<"federation-upstream">>, <<"bunny">>,
      [{<<"uri">>, <<"amqp://">>},
       {<<"reconnect-delay">>, 600000}]),
    Config.

set_policy(Config) ->
    rabbit_ct_broker_helpers:set_policy(
      Config, 0,
      <<"fed">>, <<".*">>, <<"all">>, [{<<"federation-upstream-set">>, <<"all">>}]).

init_per_group(_, Config) ->
    Config.

end_per_group(_, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Testcases.
%% -------------------------------------------------------------------
federation_links(Config) ->
    DefaultExchanges = [<<"amq.direct">>, <<"amq.fanout">>, <<"amq.headers">>,
                        <<"amq.match">>, <<"amq.topic">>],
    Running = [{X, <<"bunny">>, <<"running">>} || X <- DefaultExchanges],
    Down = [{X, <<"broken-bunny">>, <<"error">>} || X <- DefaultExchanges],
    All = lists:sort(Running ++ Down),
    Verify = fun(Result) ->
                     All == lists:sort(Result)
             end,
    %% Verify we have 5 running links and 5 down links
    wait_until(fun() ->
                       AllLinks = http_get(Config, "/federation-links"),
                       Result = [{maps:get(exchange, Link),
                                  maps:get(upstream, Link),
                                  maps:get(status, Link)} || Link <- AllLinks],
                       Verify(Result)
               end).

federation_down_links(Config) ->
    DefaultExchanges = [<<"amq.direct">>, <<"amq.fanout">>, <<"amq.headers">>,
                        <<"amq.match">>, <<"amq.topic">>],
    Down = lists:sort([{X, <<"broken-bunny">>, <<"error">>} || X <- DefaultExchanges]),
    %% we might have to wait for all links to get into 'error' status,
    %% but no other status is allowed on the meanwhile
    Verify = fun(Result) ->
                     lists:all(fun({_, _, <<"error">>}) ->
                                       true;
                                  (_) ->
                                       throw(down_links_returned_wrong_status)
                               end, Result) andalso (Down == lists:sort(Result))
             end,
    wait_until(fun() ->
                       AllLinks = http_get(Config, "/federation-links/state/down"),
                       Result = [{maps:get(exchange, Link),
                                  maps:get(upstream, Link),
                                  maps:get(status, Link)} || Link <- AllLinks],
                       Verify(Result)
               end).

restart_link(Config) ->
    try
        federation_down_links(Config),
        http_put(Config, "/users/myuser", [{password, <<"myuser">>}, {tags, <<"">>},
                                           {username, <<"myuser">>}],
                 [?CREATED, ?NO_CONTENT]),
        http_put(Config, "/permissions/%2F/myuser",
                 [{configure, <<".*">>}, {write, <<".*">>}, {read, <<".*">>},
                  {vhost, <<"/">>}, {username, <<"myuser">>}],
                 [?CREATED, ?NO_CONTENT]),
        Links = http_get(Config, "/federation-links/state/down"),
        [http_delete(Config, restart_uri(Link)) || Link <- Links],
        wait_until(fun() ->
                           [] == http_get(Config, "/federation-links/state/down")
                   end)
    after
        http_delete(Config, "/users/myuser"),
        rabbit_ct_broker_helpers:clear_policy(Config, 0, <<"fed">>),
        set_policy(Config)
    end.

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------
wait_until(Fun) ->
    wait_until(Fun, 600).

wait_until(_Fun, 0) ->
    throw(federation_links_timeout);
wait_until(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(1000),
            wait_until(Fun, N-1)
    end.

restart_uri(Link) ->
    "/federation-links/vhost/%2f/" ++
        binary_to_list(maps:get(id, Link)) ++ "/" ++
        binary_to_list(maps:get(node, Link)) ++ "/restart".

%% -------------------------------------------------------------------
%% Helpers from rabbitmq_management tests
%% -------------------------------------------------------------------
http_get(Config, Path) ->
    http_get(Config, Path, ?OK).

http_get(Config, Path, CodeExp) ->
    http_get(Config, Path, "guest", "guest", CodeExp).

http_get(Config, Path, User, Pass, CodeExp) ->
    {ok, {{_HTTP, CodeAct, _}, Headers, ResBody}} =
        req(Config, 0, get, Path, [auth_header(User, Pass)]),
    assert_code(CodeExp, CodeAct, "GET", Path, ResBody),
    decode(CodeExp, Headers, ResBody).

http_put(Config, Path, List, CodeExp) ->
    http_put_raw(Config, Path, format_for_upload(List), CodeExp).

http_put_raw(Config, Path, Body, CodeExp) ->
    http_upload_raw(Config, put, Path, Body, "guest", "guest", CodeExp, []).

http_put_raw(Config, Path, Body, User, Pass, CodeExp) ->
    http_upload_raw(Config, put, Path, Body, User, Pass, CodeExp, []).

http_upload_raw(Config, Type, Path, Body, User, Pass, CodeExp, MoreHeaders) ->
    {ok, {{_HTTP, CodeAct, _}, Headers, ResBody}} =
    req(Config, 0, Type, Path, [auth_header(User, Pass)] ++ MoreHeaders, Body),
    assert_code(CodeExp, CodeAct, Type, Path, ResBody),
    decode(CodeExp, Headers, ResBody).

http_delete(Config, Path) ->
    http_delete(Config, Path, "guest", "guest", ?NO_CONTENT).

http_delete(Config, Path, User, Pass, CodeExp) ->
    {ok, {{_HTTP, CodeAct, _}, Headers, ResBody}} =
        req(Config, 0, delete, Path, [auth_header(User, Pass)]),
    assert_code(CodeExp, CodeAct, "DELETE", Path, ResBody),
    decode(CodeExp, Headers, ResBody).

format_for_upload(none) ->
    <<"">>;
format_for_upload(List) ->
    iolist_to_binary(rabbit_json:encode(List)).

req(Config, Node, Type, Path, Headers) ->
    httpc:request(Type, {uri_base_from(Config, Node) ++ Path, Headers}, ?HTTPC_OPTS, []).

req(Config, Node, Type, Path, Headers, Body) ->
    httpc:request(Type, {uri_base_from(Config, Node) ++ Path, Headers, "application/json", Body},
                  ?HTTPC_OPTS, []).

uri_base_from(Config, Node) ->
    binary_to_list(
      rabbit_mgmt_format:print(
        "http://localhost:~w/api",
        [mgmt_port(Config, Node)])).

auth_header(Username, Password) ->
    {"Authorization",
     "Basic " ++ binary_to_list(base64:encode(Username ++ ":" ++ Password))}.

mgmt_port(Config, Node) ->
    rabbit_ct_broker_helpers:get_node_config(Config, Node, tcp_port_mgmt).

amqp_port(Config, Node) ->
    rabbit_ct_broker_helpers:get_node_config(Config, Node, tcp_port_amqp).

assert_code(CodesExpected, CodeAct, Type, Path, Body) when is_list(CodesExpected) ->
    case lists:member(CodeAct, CodesExpected) of
        true ->
            ok;
        false ->
            throw({expected, CodesExpected, got, CodeAct, type, Type,
                   path, Path, body, Body})
    end;
assert_code(CodeExp, CodeAct, Type, Path, Body) ->
    case CodeExp of
        CodeAct -> ok;
        _       -> throw({expected, CodeExp, got, CodeAct, type, Type,
                          path, Path, body, Body})
    end.

decode(?OK, _Headers,  ResBody) ->
    cleanup(rabbit_json:decode(rabbit_data_coercion:to_binary(ResBody)));
decode(_,    Headers, _ResBody) -> Headers.

cleanup(L) when is_list(L) ->
    [cleanup(I) || I <- L];
cleanup(M) when is_map(M) ->
    maps:fold(fun(K, V, Acc) ->
        Acc#{binary_to_atom(K, latin1) => cleanup(V)}
              end, #{}, M);
cleanup(I) ->
    I.
