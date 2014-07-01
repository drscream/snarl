-module(snarl_org).
-include("snarl.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([
         sync_repair/2,
         list/0,
         list_/0,
         list/2,
         get/1,
         get_/1,
         raw/1,
         lookup/1,
         add/1,
         delete/1,
         set/2,
         set/3,
         create/2,
         import/2,
         trigger/3,
         add_trigger/2, remove_trigger/2,
         remove_target/2,
         wipe/1
        ]).

-ignore_xref([
              wipe/1,
              list_/0,
              list/0,
              get/1,
              get_/1,
              lookup/1,
              add/1,
              delete/1,
              set/2,
              set/3,
              create/2,
              import/2,
              trigger/3,
              add_trigger/2, remove_trigger/2, raw/1, sync_repair/2
             ]).

-ignore_xref([create/2]).

-define(TIMEOUT, 5000).

-type template() :: [binary()|placeholder].
%% Public API

wipe(UUID) ->
    snarl_coverage:start(snarl_org_vnode_master, snarl_org,
                         {wipe, UUID}).

sync_repair(UUID, Obj) ->
    do_write(UUID, sync_repair, Obj).

add_trigger(Org, Trigger) ->
    do_write(Org, add_trigger, {uuid:uuid4s(), Trigger}).

remove_target(Org, Target) ->
    do_write(Org, remove_target, Target).

remove_trigger(Org, Trigger) ->
    do_write(Org, remove_trigger, Trigger).

trigger(Org, Event, Payload) ->
    case get_(Org) of
        {ok, OrgObj} ->
            Triggers = [T || {_, T} <- snarl_org_state:triggers(OrgObj)],
            Executed = do_events(Triggers, Event, Payload, 0),
            {ok, Executed};
        R  ->
            R
    end.

do_events([{Event, Template}|Ts], Event, Payload, N) ->
    do_event(Template, Payload),
    do_events(Ts, Event, Payload, N+1);

do_events([_|Ts], Event, Payload, N) ->
    do_events(Ts, Event, Payload, N);

do_events([], _Event, _Payload, N) ->
    N.

-spec do_event(Action::{grant, role, Role::fifo:role_id(), Template::template()} |
                       {grant, user, User::fifo:user_id(), Template::template()} |
                       {join, role, Role::fifo:role_id()} |
                       {join, org, Org::fifo:org_id()},
               Payload::template()) ->
                      ok.

do_event({join, role, Role}, Payload) ->
    snarl_user:join(Payload, Role),
    ok;

do_event({join, org, Org}, Payload) ->
    snarl_user:join_org(Payload, Org),
    snarl_user:select_org(Payload, Org),
    ok;

do_event({grant, role, Role, Template}, Payload) ->
    snarl_role:grant(Role, build_template(Template, Payload)),
    ok;

do_event({grant, user, Role, Template}, Payload) ->
    snarl_user:grant(Role, build_template(Template, Payload)),
    ok.

build_template(Template, Payload) ->
    lists:map(fun(placeholder) ->
                      Payload;
                 (E) ->
                      E
              end, Template).


import(Org, Data) ->
    do_write(Org, import, Data).

-spec lookup(OrgName::binary()) ->
                    not_found |
                    {error, timeout} |
                    {ok, Org::fifo:org()}.

lookup(OrgName) ->
    {ok, Res} = snarl_coverage:start(
                  snarl_org_vnode_master, snarl_org,
                  {lookup, OrgName}),
    R0 = lists:foldl(fun (not_found, Acc) ->
                             Acc;
                         (R, _) ->
                             {ok, R}
                     end, not_found, Res),
    case R0 of
        {ok, UUID} ->
            snarl_org:get(UUID);
        R ->
            R
    end.

-spec get(Org::fifo:org_id()) ->
                 not_found |
                 {error, timeout} |
                 {ok, Org::fifo:org()}.
get(Org) ->
    case get_(Org) of
        {ok, OrgObj} ->
            {ok, snarl_org_state:to_json(OrgObj)};
        R  ->
            R
    end.

-spec get_(Org::fifo:org_id()) ->
                  not_found |
                  {error, timeout} |
                  {ok, Org::snarl_org_state:organisation()}.
get_(Org) ->
    case snarl_entity_read_fsm:start(
           {snarl_org_vnode, snarl_org},
           get, Org
          ) of
        {ok, not_found} ->
            not_found;
        R ->
            R
    end.

raw(Org) ->
    snarl_entity_read_fsm:start({snarl_org_vnode, snarl_org}, get,
                                Org, undefined, true).

list_() ->
    {ok, Res} = snarl_full_coverage:start(
                  snarl_org_vnode_master, snarl_org,
                  {list, [], true, true}),
    Res1 = [R || {_, R} <- Res],
    {ok,  Res1}.

-spec list() -> {ok, [fifo:org_id()]} |
                not_found |
                {error, timeout}.

list() ->
    snarl_coverage:start(
      snarl_org_vnode_master, snarl_org,
      list).

-spec list([fifo:matcher()], boolean()) -> {error, timeout} | {ok, [fifo:uuid()]}.

list(Requirements, true) ->
    {ok, Res} = snarl_full_coverage:start(
                  snarl_org_vnode_master, snarl_org,
                  {list, Requirements, true}),
    Res1 = rankmatcher:apply_scales(Res),
    {ok,  lists:sort(Res1)};

list(Requirements, false) ->
    {ok, Res} = snarl_coverage:start(
                  snarl_org_vnode_master, snarl_org,
                  {list, Requirements}),
    Res1 = rankmatcher:apply_scales(Res),
    {ok,  lists:sort(Res1)}.

-spec add(Org::binary()) ->
                 {ok, UUID::fifo:org_id()} |
                 douplicate |
                 {error, timeout}.

add(Org) ->
    UUID = uuid:uuid4s(),
    create(UUID, Org).

create(UUID, Org) ->
    case snarl_org:lookup(Org) of
        not_found ->
            ok = do_write(UUID, add, Org),
            {ok, UUID};
        {ok, _OrgObj} ->
            duplicate
    end.

-spec delete(Org::fifo:org_id()) ->
                    ok |
                    not_found|
                    {error, timeout}.

delete(Org) ->
    Res = do_write(Org, delete),
    spawn(
      fun () ->
              Prefix = [<<"orgs">>, Org],
              {ok, Users} = snarl_user:list(),
              [begin
                   snarl_user:leave_org(U, Org),
                   snarl_user:revoke_prefix(U, Prefix)
               end || U <- Users],
              {ok, Roles} = snarl_role:list(),
              [snarl_role:revoke_prefix(R, Prefix) || R <- Roles],
              {ok, Orgs} = snarl_org:list(),
              [snarl_org:remove_target(O, Org) || O <- Orgs]
      end),
    Res.


-spec set(Org::fifo:org_id(), Attirbute::fifo:key(), Value::fifo:value()) ->
                 not_found |
                 {error, timeout} |
                 ok.
set(Org, Attribute, Value) ->
    set(Org, [{Attribute, Value}]).

-spec set(Org::fifo:org_id(), Attirbutes::fifo:attr_list()) ->
                 not_found |
                 {error, timeout} |
                 ok.
set(Org, Attributes) ->
    do_write(Org, set, Attributes).


%%%===================================================================
%%% Internal Functions
%%%===================================================================

do_write(Org, Op) ->
    snarl_entity_write_fsm:write({snarl_org_vnode, snarl_org}, Org, Op).

do_write(Org, Op, Val) ->
    snarl_entity_write_fsm:write({snarl_org_vnode, snarl_org}, Org, Op, Val).
