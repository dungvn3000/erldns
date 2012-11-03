-module(erldns_handler).

-include("dns_records.hrl").

-export([handle/2, build_response/2]).

%% Handle the decoded message
handle({trailing_garbage, DecodedMessage, _}, Host) ->
  handle(DecodedMessage, Host);
handle(DecodedMessage, Host) when is_record(DecodedMessage, dns_message) ->
  lager:debug("From host ~p received decoded message: ~p", [Host, DecodedMessage]),
  Questions = DecodedMessage#dns_message.questions,
  case lists:any(fun(Q) -> Q#dns_query.type =:= ?DNS_TYPE_ANY end, Questions) of
    true ->
      lager:debug("Questions: ~p", [Questions]),
      lager:debug("Refusing to respond to ANY query"),
      DecodedMessage#dns_message{rc = ?DNS_RCODE_REFUSED};
    false ->
      lager:info("Questions: ~p", [Questions]),
      Message = handle_message(DecodedMessage, Questions, Host),
      erldns_axfr:optionally_append_soa(erldns_edns:handle(Message))
  end;
handle(BadMessage, Host) ->
  lager:error("Received a bad message: ~p from ~p", [BadMessage, Host]),
  BadMessage.

%% Handle the message by hitting the packet cache and either
%% using the cached packet or continuing with the lookup process.
handle_message(DecodedMessage, Questions, Host) ->
  case erldns_packet_cache:get(Questions) of
    {ok, Answers} -> 
      lager:debug("Packet cache hit"),
      %folsom_metrics:notify({packet_cache_hit, 1}),
      build_response(Answers, DecodedMessage);
    {error, _} -> 
      lager:debug("Packet cache miss"),
      %folsom_metrics:notify({packet_cache_miss, 1}),
      case check_soa(Questions) of
        true ->
          Response = answer_questions(Questions, DecodedMessage, Host),
          erldns_packet_cache:put(Questions, Response#dns_message.answers),
          Response;
        _ ->
          %% TODO: should this response be packet cached?
          nxdomain_response(DecodedMessage)
      end
  end.

%% Check to see if we are authoritative for the domain.
check_soa(Questions) ->
  case get_soas(Questions) of
    [] -> false;
    _ -> true
  end.

%% Check all of the questions against all of the responders.
%% TODO: optimize to return first match
%% TODO: rescue from case where soa function is not defined.
get_soas(Questions) ->
  lists:flatten(lists:map(fun(Q) -> [F([Q#dns_query.name]) || F <- soa_functions()] end, Questions)).

%% Get metadata for the domain connected to the given query name.
get_metadata(Qname) ->
  lists:merge([F(Qname) || F <- metadata_functions()]).

%% Answer the questions and return an updated copy of the given
%% Response.
answer_questions([], Response, _Host) ->
  Response;
answer_questions([Q|Rest], Response, Host) ->
  [Qname, Qtype] = [Q#dns_query.name, Q#dns_query.type],
  answer_questions(Rest, build_response(lists:flatten(resolve_cnames(Qtype, answer_question(Qname, Qtype, Host), Host)), Response), Host).

%% Retreive all answers to the specific question.
answer_question(Qname, Qtype = ?DNS_TYPE_AXFR_NUMBER, Host) ->
  lager:info("Answers AXFR question for host ~p", [Host]),
  case erldns_axfr:is_enabled(Host, get_metadata(Qname)) of
    true -> query_responders(Qname, Qtype);
    _ ->
      lager:info("AXFR not allowed."),
      []
  end;
answer_question(Qname, Qtype, _) ->
  query_responders(Qname, Qtype).

%% Get the answers for a query from the responders.
query_responders(Qname, Qtype) ->
  query_responders(Qname, Qtype, answer_functions()).
query_responders(_Qname, _Qtype, []) -> [];
query_responders(Qname, Qtype, [F|AnswerFunctions]) ->
  case Answers = F(Qname, dns:type_name(Qtype)) of
    [] -> query_responders(Qname, Qtype, AnswerFunctions);
    _ -> Answers
  end.

% Return an NXDOMAIN response since we are not authoritative.
nxdomain_response(Message) ->
  Message#dns_message{anc = 0, qr = true, aa = false, rc = ?DNS_RCODE_NXDOMAIN, answers = []}.

%% Populate a response with the given answers
build_response(Answers, Response) ->
  case lists:all(fun(A) -> A#dns_rr.type =:= ?DNS_TYPE_NS end, Answers) of
    true -> Response#dns_message{auc = length(Answers), qr = true, aa = false, authority = Answers};
    false -> Response#dns_message{anc = length(Answers), qr = true, aa = true, answers = Answers}
  end.

%% Build a list of answer functions based on the registered responders.
answer_functions() ->
  lists:map(fun(M) -> fun M:answer/2 end, get_responder_modules()).

%% Build a list of functions for looking up SOA records based on the
%% registered responders.
soa_functions() ->
  lists:map(fun(M) -> fun M:get_soa/1 end, get_responder_modules()).

%% Build a list of functions for getting metdata based on the registered
%% responders.
metadata_functions() ->
  lists:map(fun(M) -> fun M:get_metadata/1 end, get_responder_modules()).

%% Find the responder module names from the app environment. Default 
%% to just the erldns_mysql_responder.
get_responder_modules() -> get_responder_modules(application:get_env(erldns, responders)).
get_responder_modules({ok, RM}) -> RM;
get_responder_modules(_) -> [erldns_mysql_responder].

%% According to RFC 1034:
%%
%% "CNAME RRs cause special action in DNS software.
%% When a name server fails to find a desired RR
%% in the resource set associated with the domain name,
%% it checks to see if the resource set consists
%% of a CNAME record with a matching class.  If so, the
%% name server includes the CNAME record in the
%% response and restarts the query at the domain name
%% specified in the data field of the CNAME record.
%% The one exception to this rule is that queries which
%% match the CNAME type are not restarted."
resolve_cnames(Qtype, Records, Host) ->
  case Qtype of
    ?DNS_TYPE_CNAME_NUMBER -> Records;
    ?DNS_TYPE_AXFR_NUMBER -> Records;
    ?DNS_TYPE_ANY_NUMBER -> Records;
    _ -> [resolve_cname(Qtype, Record, Host) || Record <- Records]
  end.

%% Restart the query.
resolve_cname(OriginalQtype, Record, Host) ->
  lager:debug("~p:resolve_cname(~p, ~p, ~p)~n", [?MODULE, OriginalQtype, Record, Host]),
  case Record#dns_rr.type of
    ?DNS_TYPE_CNAME_NUMBER ->
      Qname = Record#dns_rr.data#dns_rrdata_cname.dname,
      answer_question(Qname, OriginalQtype, Host) ++ [Record];
    _ ->
      Record
  end.
