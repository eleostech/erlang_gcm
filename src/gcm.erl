-module(gcm).

-include_lib("eunit/include/eunit.hrl").

-include("gcm.hrl").

-record(gcm_message,
        {registration_ids,
         data,
         dry_run=false}).

-export([send/2, send/3]).

send(Tokens, PropList) ->
    ApiKey = case get_env(api_key, undefined) of
                 Key when is_list(Key) ->
                     Key;
                 _ ->
                     throw(gcm_api_key_unspecified)
             end,
    send(ApiKey, Tokens, PropList).

send(ApiKey, Tokens, PropList) ->
    Ids = lists:map(fun(Token) ->
                            list_to_binary(Token)
                    end, Tokens),
    GcmMessage = #gcm_message{registration_ids=Ids,
                              data={PropList}},
    Data = jiffy:encode({gcm_message_to_proplist(GcmMessage)}),
    case post_json(ApiKey, Data) of
        {ok, JsonResponse} ->
            {ok, json_to_gcm_response(JsonResponse)};
        Other ->
            Other
    end.

post_json(ApiKey, Json) ->
    Endpoint = get_env(endpoint, "https://android.googleapis.com/gcm/send"),
    case ibrowse:send_req(Endpoint,
                          [{"Content-Type", "application/json"},
                           {"Authorization", lists:append("key=", ApiKey)}],
                          post,
                          Json) of
        {ok, "200", _Headers, Body} ->
            {ok, Body};
        {ok, "401", _, _} ->
            {error, unauthorized};
        {ok, Code, _, Body} ->
            {error, unknown, Code, Body};
        {error, Problem} ->
            {error, Problem};
        Else ->
            {error, Else}
    end.

gcm_message_to_proplist(#gcm_message{} = GcmMessage) ->
    lists:zip(record_info(fields, gcm_message),
              tl(tuple_to_list(GcmMessage))).

json_to_gcm_response(Json) ->
    {PropList} = jiffy:decode(list_to_binary(Json)),
    RawResults = proplists:get_value(<<"results">>, PropList),
    Results = lists:map(fun({Result}) ->
                                #gcm_result{message_id=list_value(message_id, Result),
                                            canonical_id=list_value(registration_id, Result),
                                            error=name_for_error(list_value(error, Result))}
                        end, RawResults),
    #gcm_response{multicast_id=proplists:get_value(<<"multicast_id">>, PropList),
                  results=Results}.


name_for_error("NotRegistered") ->
    not_registered;
name_for_error("Unavailable") ->
    unavailable; % Can be retried at a later date
name_for_error("MissingRegistration") ->
    missing_registration;
name_for_error("InvalidRegistration") ->
    invalid_registration;
name_for_error("MismatchSenderId") ->
    mismatch_sender_id;
name_for_error("MessageTooBig") ->
    message_too_big;
name_for_error("InvalidDataKey") ->
    invalid_data_key;
name_for_error("InvalidTtl") ->
    invalid_ttl;
name_for_error(undefined) ->
    undefined.


%% Retrieve the given key, assuming that PropList has both keys
%% and values as binaries, not lists
list_value(Key, PropList) when is_atom(Key) ->
    list_value(atom_to_list(Key), PropList);
list_value(Key, PropList) when is_list(Key) ->
    list_value(list_to_binary(Key), PropList);
list_value(Key, PropList) when is_binary(Key) ->
    case proplists:get_value(Key, PropList) of
        undefined ->
            undefined;
        Other ->
            binary_to_list(Other)
    end.

get_env(K, Def) ->
  case application:get_env(gcm, K) of
    {ok, V} -> V;
    _ -> Def
  end.

-ifdef(TEST).

mock_env(Endpoint, Key, Fun) ->
    meck:new(application, [unstick]),
    meck:expect(application, get_env, fun(gcm, endpoint) ->
                                              case Endpoint of
                                                  undefined ->
                                                      undefined;
                                                  _ ->
                                                      {ok, Endpoint}
                                              end;
                                         (gcm, api_key) ->
                                              case Key of
                                                  undefined ->
                                                      undefined;
                                                  _ ->
                                                      {ok, Key}
                                              end
                                      end),
    Fun(),
    meck:unload(application).

send_complains_if_no_key_test() ->
    mock_env(undefined, undefined,
             fun() ->
                     ?assertException(throw, gcm_api_key_unspecified,
                                      send([fake], []))
             end).

post_json_uses_specified_endpoint_test() ->
    meck:new(ibrowse),
    meck:expect(ibrowse, send_req,
                fun(Endpoint, _, _, _) ->
                        ?assertEqual("endpoint", Endpoint),
                        {ok, "200", [], ""}
                end),
    mock_env("endpoint", "sesame",
             fun() ->
                     post_json("fake key", "")
             end),
    meck:validate(ibrowse),
    meck:unload(ibrowse).

post_json_sends_key_test() ->
    meck:new(ibrowse),
    meck:expect(ibrowse, send_req,
                fun(_, Headers, post, _) ->
                        AuthHeader = proplists:get_value("Authorization", Headers),
                        ?assertEqual("key=sesame", AuthHeader),
                        {ok, "200", [], ""}
                end),
    post_json("sesame", ""),
    meck:validate(ibrowse),
    meck:unload(ibrowse).

get_env_test() ->
    ?assertEqual("default", get_env(therbligs, "default")),
    meck:new(application, [unstick]),
    meck:expect(application, get_env, fun(gcm, therbligs) -> {ok, "nine thousand"} end),
    ?assertEqual("nine thousand", get_env(therbligs, "default")),
    meck:unload(application).

gcm_message_to_proplist_test() ->
    List = gcm_message_to_proplist(#gcm_message{registration_ids = ["1", "2"],
                                                data="threeve"}),
    ?assertEqual(["1", "2"], proplists:get_value(registration_ids, List)),
    ?assertEqual("threeve", proplists:get_value(data, List)).

json_to_gcm_response_test() ->
    ?assertEqual(#gcm_response{multicast_id=7808951470915862768,
                               results=[#gcm_result{message_id="0:1358785809261537%2ba1ffbff9fd7ecd"}]},
                 json_to_gcm_response("{\"multicast_id\":7808951470915862768,\"success\":1,\"failure\":0,\"canonical_ids\":0,\"results\":[{\"message_id\":\"0:1358785809261537%2ba1ffbff9fd7ecd\"}]}")),
    ?assertEqual(#gcm_response{multicast_id=5157392462655390413,
                               results=[#gcm_result{error=not_registered}]},
                 json_to_gcm_response("{\"multicast_id\":5157392462655390413,\"success\":0,\"failure\":1,\"canonical_ids\":0,\"results\":[{\"error\":\"NotRegistered\"}]}")).

send_response_test() ->
    meck:new(ibrowse),
    meck:expect(ibrowse, send_req,
                fun(_, _, post, _) ->
                        {ok, "200", [], "{\"multicast_id\":5,\"success\":1,\"failure\":0,\"canonical_ids\":0,\"results\":[{\"message_id\":\"42\"}]}"}
                end),
    mock_env("nowhere", "sesame",
             fun() ->
                     {ok, Response} = send(["token"], []),
                     ?assertEqual(#gcm_response{multicast_id=5,
                                                results=[#gcm_result{message_id="42", canonical_id=undefined}]},
                                 Response)
             end),
    meck:validate(ibrowse),
    meck:unload(ibrowse).

canonical_id_response_test() ->
    meck:new(ibrowse),
    meck:expect(ibrowse, send_req,
                fun(_, _, post, _) ->
                        {ok, "200", [], "{\"multicast_id\":5,\"success\":1,\"failure\":0,\"canonical_ids\":1,\"results\":[{\"message_id\":\"42\",\"registration_id\":\"sigh\"}]}"}
                end),
    mock_env("nowhere", "sesame",
             fun() ->
                     {ok, Response} = send(["token"], []),
                     ?assertEqual(#gcm_response{multicast_id=5,
                                                results=[#gcm_result{message_id="42", canonical_id="sigh"}]},
                                 Response)
             end),
    meck:validate(ibrowse),
    meck:unload(ibrowse).

send_unauthorized_test() ->
    meck:new(ibrowse),
    meck:expect(ibrowse, send_req,
                fun(_, _, post, _) ->
                        {ok, "401", [], ""}
                end),
    mock_env("nowhere", "sesame",
             fun() ->
                     Result = send(["token"], []),
                     ?assertEqual({error, unauthorized}, Result)
             end),
    meck:validate(ibrowse),
    meck:unload(ibrowse).

-endif.
