/*
    Copyright © 2011 MLstate

    This file is part of OPA.

    OPA is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    OPA is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with OPA.  If not, see <http://www.gnu.org/licenses/>.
*/

/**
 * MongoDB binding for OPA.
 *
 * @destination public
 * @stabilization work in progress
 **/

/**
 * {1 About this module}
 *
 * This is a binding for MongoDB for OPA, loosely based around the C drivers.
 *
 * Module [MongoDriver] has low-level routines to talk to the database server, the only
 * routines you should need are the [MongoDriver.open] and [MongoDriver.close] functions.
 *
 * {1 Where should I start?}
 *
 * {1 What if I need more?}
 *
 **/

import stdlib.core.{date,rpc.core}
import stdlib.io.socket
import stdlib.crypto
import stdlib.system

/** Some external types **/

type Mongo.mongo_buf = external
type Mongo.cursorID = external
type Mongo.mailbox = external
type Mongo.reply = external

/** Type for a connection, host name and port **/
type Mongo.mongo_host = (string, int)

/**
 * Main connection type.
 * Stores the socket connection plus other parameters such as
 * the seeds and primary status for a replica set, timing
 * parameters for reconnection and a limiter for recursion depth.
 **/
@abstract
type Mongo.db = {
  conn : Mutable.t(option(Socket.connection));
  conncell : Cell.cell(Mongo.sr,Mongo.srr);
  primary : Mutable.t(option(Mongo.mongo_host));
  bufsize : int;
  log : bool;
  name : string;
  seeds : list(Mongo.mongo_host);
  hosts : Mutable.t(list(Mongo.mongo_host));
  reconnect_wait : int;
  max_attempts : int;
  comms_timeout : int;
  reconnect : Mutable.t(option(Mongo.db -> outcome(Mongo.db,Mongo.failure)));
  depth : Mutable.t(int);
  max_depth : int;
}

/** Outgoing Cell messages **/
type Mongo.sr =
    {send:(Mongo.db,Mongo.mongo_buf,string)} // Send and forget
  / {sendrecv:(Mongo.db,Mongo.mongo_buf,string)} // Send and expect reply
  / {senderror:(Mongo.db,Mongo.mongo_buf,string,string)} // Send and call getlasterror
  / {stop} // Stop the cell

/** Incoming Cell messages **/
type Mongo.srr =
    {sendresult:bool}
  / {sndrcvresult:option(Mongo.reply)}
  / {snderrresult:option(Mongo.reply)}
  / {stopresult}
  / {reconnect}

/**
 * Mongo driver failure status.
 * Either a failure document returned by the MongoDB server,
 * an error string generated by the driver or [Incomplete]
 * which signals that expected fields were missing from a reply.
 **/
type Mongo.failure =
    {Error : string}
  / {DocError : Bson.document}
  / {Incomplete}

/**
 * Mongo success status, just a document.
 **/
type Mongo.success = Bson.document
type Mongo.successes = list(Bson.document)

/**
 * A Mongo driver result value is either a valid document
 * or a [Mongo.failure] value.
 **/
type Mongo.result = outcome(Mongo.success, Mongo.failure)
type Mongo.results = outcome(Mongo.successes, Mongo.failure)

/**
 * A Mongo error is either an error value which is an OPA
 * value containing the error information from a [Bson.document]
 * or a [Mongo.failure] value.
 **/
type Mongo.error = outcome(Bson.error, Mongo.failure)

/* Flag tags */

/** OP_INSERT **/
type Mongo.insert_tag =
  {ContinueOnError}

/** OP_UPDATE **/
type Mongo.update_tag =
  {Upsert} /
  {MultiUpdate}

/** OP_QUERY **/
type Mongo.query_tag =
  {TailableCursor} /
  {SlaveOk} /
  {OplogReplay} /
  {NoCursorTimeout} /
  {AwaitData} /
  {Exhaust} /
  {Partial}

/** OP_DELETE **/
type Mongo.delete_tag =
  {SingleRemove}

/** OP_REPLY **/
type Mongo.reply_tag =
  {CursorNotFound} /
  {QueryFailure} /
  {ShardConfigStale} /
  {AwaitCapable}

/**
 *  We wrap the tags so that we can tell if it is an insert tag,
 *  query tag etc.  We don't want to send SingleRemove to an update.
 **/
type Mongo.mongo_tag =
  {itag:Mongo.insert_tag} /
  {utag:Mongo.update_tag} /
  {qtag:Mongo.query_tag} /
  {dtag:Mongo.delete_tag} /
  {rtag:Mongo.reply_tag}

/** Tags for indices **/
type Mongo.index_tag =
  {Unique} /
  {DropDups} /
  {Background} /
  {Sparse}

@server_private
MongoDriver = {{

  @private ML = MongoLog
  @private H = Bson.Abbrevs

  /** The MongoDB default port number **/
  default_port = 27017

  /**
   * Some routines for manipulating outcomes from Mongo commands.
   **/

  /**
   * Some code to handle outcomes.
   **/
  map_outcome(outcome:outcome('s,'f), sfn:'s->'t, ffn:'f->'g): outcome('t,'g) =
    match outcome with
    | {~success} -> {success=sfn(success)}
    | {~failure} -> {failure=ffn(failure)}

  map_success(outcome, sfn) = map_outcome(outcome, sfn, (f -> f))
  map_failure(outcome, ffn) = map_outcome(outcome, (s -> s), ffn)

  outcome_map(outcome:outcome('s,'f), sfn:'s->'r, ffn:'f->'r): 'r =
    match outcome with
    | {~success} -> sfn(success)
    | {~failure} -> ffn(failure)

  string_of_outcome = (outcome_map:outcome('s,'f), ('s->string), ('f->string) -> string)

  /** Turn a result into a [Mongo.error] value **/
  error_of_result(result:Mongo.result): Mongo.error = map_success(result, Bson.error_of_document)

  /** Make a readable string out of a [Mongo.error] value **/
  string_of_error(error:Mongo.error): string = outcome_map(error, Bson.string_of_error, string_of_failure)

  /** String representation of a [Mongo.failure] value **/
  string_of_failure(failure:Mongo.failure): string =
    match failure with
    | {Error=str} -> str
    | {DocError=doc} -> Bson.string_of_doc_error(doc)
    | {Incomplete} -> "Incomplete"

  /** Make an error report string out of a [Mongo.result] value, will print "<ok>" if no error. **/
  string_of_result(result:Mongo.result): string = outcome_map(result, Bson.string_of_doc_error, string_of_failure)

  /** Same for a list of results. **/
  string_of_results(results:Mongo.results): string =
    outcome_map(results, (l -> List.list_to_string(Bson.string_of_doc_error,l)), string_of_failure)

  /** Similar to [string_of_result] but the success value is user-defined. **/
  string_of_value_or_failure(result:outcome('a,Mongo.failure), success_to_str:'a->string): string =
    string_of_outcome(result, success_to_str, (failure -> "\{failure={string_of_failure(failure)}\}"))

  /** Either pretty-print the document or generate a failure string. **/
  pretty_of_result(result:Mongo.result): string = string_of_value_or_failure(result,Bson.to_pretty)

  /** Same as [pretty_of_result] but for a list of results. **/
  pretty_of_results(results:Mongo.results): string =
    string_of_value_or_failure(results,(l -> List.list_to_string(Bson.to_pretty,l)))

  /** Predicate for error status of a [Mongo.result] value. **/
  is_error(result:Mongo.result): bool = outcome_map(result, Bson.is_error, (_ -> true))

  /** Predicate for error status of a [Mongo.result] value. **/
  isError(error:Mongo.error): bool = outcome_map(error, Bson.isError, (_ -> true))

  /**
   * Validate a BSON document by turning it into a [Mongo.result] value.
   * If [ok] is non-zero or there is an [errmsg] value then turn it into a [Mongo.failure] value.
   **/
  check_ok(bson:Bson.document): Mongo.result =
    match Bson.find_int(bson,"ok") with
    | {some=ok} ->
       if ok == 1
       then {success=bson}
       else
         (match Bson.find_string(bson,"errmsg") with
          | {some=errmsg} -> {failure={Error=errmsg}}
          | _ -> {failure={Error="ok:{ok}"}})
    | _ -> {success=bson}

  /**
   * Outcome-wrapped versions of Bson.find_xxx etc.
   **/
  @private
  result_(result:Mongo.result,key:string,find:(Bson.document, string -> option('a))): option('a) =
    match result with
    | {success=doc} -> find(doc,key)
    | {failure=_} -> {none}

  result_bool(result:Mongo.result,key:string): option(bool) = result_(result, key, Bson.find_bool)
  result_int(result:Mongo.result,key:string): option(int) = result_(result, key, Bson.find_int)
  result_float(result:Mongo.result,key:string): option(float) = result_(result, key, Bson.find_float)
  result_string(result:Mongo.result,key:string): option(string) = result_(result, key, Bson.find_string)
  result_doc(result:Mongo.result,key:string): option(Bson.document) = result_(result, key, Bson.find_doc)

  /**
   * Same as outcome-wrapped versions but allowing dot notation.
   **/
  @private
  dotresult_(result:Mongo.result,key:string,find:(Bson.document, string -> option('a))): option('a) =
    match result with
    | {success=doc} -> Bson.find_dot(doc,key,find)
    | {failure=_} -> {none}

  dotresult_bool(result:Mongo.result,key:string): option(bool) = dotresult_(result, key, Bson.find_bool)
  dotresult_int(result:Mongo.result,key:string): option(int) = dotresult_(result, key, Bson.find_int)
  dotresult_float(result:Mongo.result,key:string): option(float) = dotresult_(result, key, Bson.find_float)
  dotresult_string(result:Mongo.result,key:string): option(string) = dotresult_(result, key, Bson.find_string)
  dotresult_doc(result:Mongo.result,key:string): option(Bson.document) = dotresult_(result, key, Bson.find_doc)

  /**
   * If a result is success then return an OPA value from the
   * document using [Bson.doc2opa].  Must be cast at point of call.
   **/
  result_to_opa(result:Mongo.result): option('a) =
    match result with
    | {success=doc} -> (Bson.doc2opa(doc):option('a))
    | {failure=_} -> {none}

  /**
   * Same as [result_to_opa] but returning an outcome instead of an option.
   **/
  resultToOpa(result:Mongo.result): outcome('a,Mongo.failure) =
    match result with
    | {success=doc} ->
       (match (Bson.doc2opa(doc):option('a)) with
        | {some=a} -> {success=a}
        | {none} -> {failure={Error="Mongo.resultToOpa: document conversion failure"}})
    | {~failure} -> {~failure}

  /** Flag bitmasks **/

  /* OP_INSERT */
  ContinueOnErrorBit  = 0x00000001

  /* OP_UPDATE */
  UpsertBit           = 0x00000001
  MultiUpdateBit      = 0x00000002

  /* OP_QUERY */
  TailableCursorBit   = 0x00000002
  SlaveOkBit          = 0x00000004
  OplogReplayBit      = 0x00000008
  NoCursorTimeoutBit  = 0x00000010
  AwaitDataBit        = 0x00000020
  ExhaustBit          = 0x00000040
  PartialBit          = 0x00000080

  /* OP_DELETE */
  SingleRemoveBit     = 0x00000001

  /* OP_REPLY */
  CursorNotFoundBit   = 0x00000001
  QueryFailureBit     = 0x00000002
  ShardConfigStaleBit = 0x00000004
  AwaitCapableBit     = 0x00000008

  /**
   *  [flag_of_tag]:  Turn a list of tags into a bit-wise flag suitable
   *  for sending to MongoDB.  We have an extra layer of types to allow
   *  forcing of tags to belong to a particular operation.
   **/
  flag_of_tag(tag:Mongo.mongo_tag): int =
    match tag with
      /* OP_INSERT */
    | {itag={ContinueOnError}} -> ContinueOnErrorBit

      /* OP_UPDATE */
    | {utag={Upsert}} -> UpsertBit
    | {utag={MultiUpdate}} -> MultiUpdateBit

      /* OP_QUERY */
    | {qtag={TailableCursor}} -> TailableCursorBit
    | {qtag={SlaveOk}} -> SlaveOkBit
    | {qtag={OplogReplay}} -> OplogReplayBit
    | {qtag={NoCursorTimeout}} -> NoCursorTimeoutBit
    | {qtag={AwaitData}} -> AwaitDataBit
    | {qtag={Exhaust}} -> ExhaustBit
    | {qtag={Partial}} -> PartialBit

      /* OP_DELETE */
    | {dtag={SingleRemove}} -> SingleRemoveBit

      /* OP_REPLY */
    | {rtag={CursorNotFound}} -> CursorNotFoundBit
    | {rtag={QueryFailure}} -> QueryFailureBit
    | {rtag={ShardConfigStale}} -> ShardConfigStaleBit
    | {rtag={AwaitCapable}} -> AwaitCapableBit

  /**
   * Turn a list of tags into a single MongoDB-compatible int.
   **/
  flags(tags:list(Mongo.mongo_tag)): int =
    List.fold_left((flag, tag -> Bitwise.land(flag,flag_of_tag(tag))),0,tags)

  /**
   *  Extract the tags from a given bit-wise flag.  These are specific
   *  to each operation, you need to know which operation the flag was for/from
   *  before you can give meaning to the bits.
   **/
  insert_tags(flag:int): list(Mongo.mongo_tag) =
    if Bitwise.land(flag,ContinueOnErrorBit) != 0 then [{itag={ContinueOnError}}] else []

  update_tags(flag:int): list(Mongo.mongo_tag) =
    tags = if Bitwise.land(flag,UpsertBit) != 0 then [{utag={Upsert}}] else []
    if Bitwise.land(flag,MultiUpdateBit) != 0 then [{utag={MultiUpdate}}|tags] else tags

  query_tags(flag:int): list(Mongo.mongo_tag) =
    tags = if Bitwise.land(flag,TailableCursorBit) != 0 then [{qtag={TailableCursor}}] else []
    tags = if Bitwise.land(flag,SlaveOkBit) != 0 then [{qtag={SlaveOk}}|tags] else tags
    tags = if Bitwise.land(flag,OplogReplayBit) != 0 then [{qtag={OplogReplay}}|tags] else tags
    tags = if Bitwise.land(flag,NoCursorTimeoutBit) != 0 then [{qtag={NoCursorTimeout}}|tags] else tags
    tags = if Bitwise.land(flag,AwaitDataBit) != 0 then [{qtag={AwaitData}}|tags] else tags
    tags = if Bitwise.land(flag,ExhaustBit) != 0 then [{qtag={Exhaust}}|tags] else tags
    if Bitwise.land(flag,PartialBit) != 0 then [{qtag={Partial}}|tags] else tags

  delete_tags(flag:int): list(Mongo.mongo_tag) =
    if Bitwise.land(flag,SingleRemoveBit) != 0 then [{dtag={SingleRemove}}] else []

  reply_tags(flag:int): list(Mongo.mongo_tag) =
    tags = if Bitwise.land(flag,CursorNotFoundBit) != 0 then [{rtag={CursorNotFound}}] else []
    tags = if Bitwise.land(flag,QueryFailureBit) != 0 then [{rtag={QueryFailure}}|tags] else tags
    tags = if Bitwise.land(flag,ShardConfigStaleBit) != 0 then [{rtag={ShardConfigStale}}|tags] else tags
    if Bitwise.land(flag,AwaitCapableBit) != 0 then [{rtag={AwaitCapable}}|tags] else tags

  /**
   * A string representation of a [Mongo.mongo_tag] value.
   **/
  string_of_tag(tag:Mongo.mongo_tag): string =
    match tag with
    | {itag={ContinueOnError}} -> "ContinueOnError"
    | {utag={Upsert}} -> "Upsert"
    | {utag={MultiUpdate}} -> "MultiUpdate"
    | {qtag={TailableCursor}} -> "TailableCursor"
    | {qtag={SlaveOk}} -> "SlaveOk"
    | {qtag={OplogReplay}} -> "OplogReplay"
    | {qtag={NoCursorTimeout}} -> "NoCursorTimeout"
    | {qtag={AwaitData}} -> "AwaitData"
    | {qtag={Exhaust}} -> "Exhaust"
    | {qtag={Partial}} -> "Partial"
    | {dtag={SingleRemove}} -> "SingleRemove"
    | {rtag={CursorNotFound}} -> "CursorNotFound"
    | {rtag={QueryFailure}} -> "QueryFailure"
    | {rtag={ShardConfigStale}} -> "ShardConfigStale"
    | {rtag={AwaitCapable}} -> "AwaitCapable"

  /** String of a list of tags. **/
  string_of_tags(tags:list(Mongo.mongo_tag)): string = List.list_to_string(string_of_tag,tags)

  /* Allocate new buffer of given size */
  @private create_ = (%% BslMongo.Mongo.create %%: int -> Mongo.mongo_buf)

  /* Build OP_INSERT message in buffer */
  @private insert_ = (%% BslMongo.Mongo.insert %%: Mongo.mongo_buf, int, string, 'a -> void)

  /* Build OP_INSERT message in buffer */
  @private insert_batch_ = (%% BslMongo.Mongo.insert_batch %%: Mongo.mongo_buf, int, string, list('a) -> void)

  /* Build OP_UPDATE message in buffer */
  @private update_ = (%% BslMongo.Mongo.update %%: Mongo.mongo_buf, int, string, 'a, 'a -> void)

  /* Build OP_QUERY message in buffer */
  @private query_ = (%% BslMongo.Mongo.query %%: Mongo.mongo_buf, int, string, int, int, 'a, option('a) -> void)

  /* Build OP_GET_MORE message in buffer */
  @private get_more_ = (%% BslMongo.Mongo.get_more %%: Mongo.mongo_buf, string, int, Mongo.cursorID -> void)

  /* Build OP_DELETE message in buffer */
  @private delete_ = (%% BslMongo.Mongo.delete %%: Mongo.mongo_buf, int, string, 'a -> void)

  /* Build OP_KILL_CURSORS message in buffer */
  @private kill_cursors_ = (%% BslMongo.Mongo.kill_cursors %%: Mongo.mongo_buf, list('a) -> void)

  /* Build OP_MSG message in buffer */
  @private msg_ = (%% BslMongo.Mongo.msg %%: Mongo.mongo_buf, string -> void)

  /* Copies string out of buffer. */
  @private get_ = (%% BslMongo.Mongo.get %%: Mongo.mongo_buf -> string)

  /* Access the raw string and length */
  @private export_ = (%% BslMongo.Mongo.export %%: Mongo.mongo_buf -> (string, int))

  /* Create a (finished) buffer from string */
  @private import_ = (%% BslMongo.Mongo.import %%: string -> Mongo.mongo_buf)

  /* Make a copy of a buffer */
  @private copy_ = (%% BslMongo.Mongo.copy %%: Mongo.mongo_buf -> Mongo.mongo_buf)

  /* Concatenate two buffers */
  @private concat_ = (%% BslMongo.Mongo.concat %%: Mongo.mongo_buf, Mongo.mongo_buf -> Mongo.mongo_buf)

  /* Append two buffers */
  @private append_ = (%% BslMongo.Mongo.append %%: Mongo.mongo_buf, Mongo.mongo_buf -> void)

  /* Clear out any data in the buffer, leave buffer allocated */
  @private clear_ = (%% BslMongo.Mongo.clear %%: Mongo.mongo_buf -> void)

  /* Reset the buffer, unallocate storage */
  @private reset_ = (%% BslMongo.Mongo.reset %%: Mongo.mongo_buf -> void)

  /* Free the buffer, return buffer for later use */
  @private free_ = (%% BslMongo.Mongo.free %%: Mongo.mongo_buf -> void)

  /* Mailbox so we can use the streaming parser */
  @private new_mailbox_ = (%% BslMongo.Mongo.new_mailbox %%: int -> Mongo.mailbox)
  @private reset_mailbox_ = (%% BslMongo.Mongo.reset_mailbox %%: Mongo.mailbox -> void)

  /*
   * Specialised read, read until the size equals the (little endian)
   * 4-byte int at the start of the reply.
   */
  @private read_mongo_ = (%% BslMongo.Mongo.read_mongo %%: Socket.connection, int, Mongo.mailbox -> outcome(Mongo.reply,string))

  /* Support for logging routines */
  @private string_of_message = (%% BslMongo.Mongo.string_of_message %% : string -> string)
  @private string_of_message_reply = (%% BslMongo.Mongo.string_of_message_reply %% : Mongo.reply -> string)

  /* Get requestId from Mongo.mongo_buf */
  @private mongo_buf_requestId = (%% BslMongo.Mongo.mongo_buf_requestId %%: Mongo.mongo_buf -> int)

  /* Get responseTo from Mongo.mongo_buf */
  @private mongo_buf_responseTo = (%% BslMongo.Mongo.mongo_buf_responseTo %%: Mongo.mongo_buf -> int)

  /*
   * We have the possibility of unbounded recursion here since we
   * call ReplSet.connect, which calls us for ismaster.  Probably
   * won't ever be used but we limit the depth of the recursion.
   */
  @private
  reconnect(from:string, m:Mongo.db): bool =
    if m.depth.get() > m.max_depth
    then
      do if m.log then ML.error("reconnect({from})","max depth exceeded",void)
      false
    else
      ret(tf:bool) = do m.depth.set(m.depth.get()-1) tf
      do m.depth.set(m.depth.get()+1)
      match m.reconnect.get() with
      | {some=reconnectfn} ->
         rec aux(attempts) =
           if attempts > m.max_attempts
           then ret(false)
           else
             (match reconnectfn(m) with
              | {success=_} ->
                 do if m.log then ML.info("reconnect({from})","reconnected",void)
                 ret(true)
              | {~failure} ->
                 do if m.log then ML.info("reconnect({from})","failure={string_of_failure(failure)}",void)
                 do Scheduler.wait(m.reconnect_wait)
                 aux(attempts+1))
         aux(0)
      | {none} ->
         ret(false)

  @private
  send_no_reply_(m,mbuf,name,reply_expected): bool =
    match m.conn.get() with
    | {some=conn} ->
       (str, len) = export_(mbuf)
       s = String.substring(0,len,str)
       do if m.log then ML.debug("Mongo.send({name})","\n{string_of_message(s)}",void)
       (match Socket.write_len_with_err_cont(conn,m.comms_timeout,s,len) with
        | {success=cnt} ->
           do if not(reply_expected) then free_(mbuf) else void
           (cnt==len)
        | {failure=_} -> false)
    | {none} ->
       ML.error("Mongo.send({name})","Attempt to write to unopened connection",false)

  @private
  send_no_reply(m,mbuf,name): bool = send_no_reply_(m,mbuf,name,false)

  @private
  send_with_reply(m,mbuf,name): option(Mongo.reply) =
    mrid = mongo_buf_requestId(mbuf)
    match m.conn.get() with
    | {some=conn} ->
       if send_no_reply_(m,mbuf,name,true)
       then
         mailbox = new_mailbox_(m.bufsize)
         (match read_mongo_(conn,m.comms_timeout,mailbox) with
          | {success=reply} ->
             rrt = reply_responseTo(reply)
             do reset_mailbox_(mailbox)
             do free_(mbuf)
             do if m.log then ML.debug("Mongo.receive({name})","\n{string_of_message_reply(reply)}",void)
             if mrid != rrt
             then ML.error("MongoDriver.send_with_reply","RequestId mismatch, expected {mrid}, got {rrt}",{none})
             else {some=reply}
          | {~failure} ->
             do if m.log then ML.info("send_with_reply","failure={failure}",void)
             do reset_mailbox_(mailbox)
             {none})
       else {none}
    | {none} ->
       ML.error("Mongo.receive({name})","Attempt to write to unopened connection",{none})

  @private
  send_with_error(m,mbuf,name,ns): option(Mongo.reply) =
    mbuf2 = create_(m.bufsize)
    do query_(mbuf2,0,ns^".$cmd",0,1,[H.i32("getlasterror",1)],{none})
    mrid = mongo_buf_requestId(mbuf2)
    do append_(mbuf,mbuf2)
    do free_(mbuf2)
    match m.conn.get() with
    | {some=conn} ->
       if send_no_reply_(m,mbuf,name,true)
       then
         mailbox = new_mailbox_(m.bufsize)
         (match read_mongo_(conn,m.comms_timeout,mailbox) with
          | {success=reply} ->
             rrt = reply_responseTo(reply)
             do reset_mailbox_(mailbox)
             do free_(mbuf)
             do if m.log then ML.debug("Mongo.send_with_error({name})","\n{string_of_message_reply(reply)}",void)
             if mrid != rrt
             then ML.error("MongoDriver.send_with_error","RequestId mismatch, expected {mrid}, got {rrt}",{none})
             else {some=reply}
          | {~failure} ->
             do if m.log then ML.info("send_with_error","failure={failure}",void)
             do reset_mailbox_(mailbox)
             {none})
       else {none}
    | {none} ->
       ML.error("Mongo.send_with_error({name})","Attempt to write to unopened connection",{none})

  @private
  sr(_, msg) =
    match msg with
    | {send=(m,mbuf,name)} ->
       (match m.conn.get() with
        | {some=_conn} ->
           sr = send_no_reply(m,mbuf,name)
           {return=if sr then {sendresult=sr} else {reconnect}; instruction={unchanged}}
        | {none} ->
           do ML.error("Mongo.send","Unopened connection",void)
           {return={sendresult=false}; instruction={unchanged}})
    | {sendrecv=(m,mbuf,name)} ->
       (match m.conn.get() with
        | {some=_conn} ->
           swr = send_with_reply(m,mbuf,name)
           {return=if Option.is_some(swr) then {sndrcvresult=swr} else {reconnect}; instruction={unchanged}}
        | {none} ->
           do ML.error("Mongo.sendrecv","Unopened connection",void)
           {return={sndrcvresult={none}}; instruction={unchanged}})
    | {senderror=(m,mbuf,name,ns)} ->
       (match m.conn.get() with
        | {some=_conn} ->
           swe = send_with_error(m,mbuf,name,ns)
           {return=if Option.is_some(swe) then {snderrresult=swe} else {reconnect}; instruction={unchanged}}
        | {none} ->
           do ML.error("Mongo.senderror","Unopened connection",void)
           {return={snderrresult={none}}; instruction={unchanged}})
    | {stop} ->
       {return={stopresult}; instruction={stop}}

  @private
  snd(m,mbuf,name) =
    match (Cell.call(m.conncell,({send=((m,mbuf,name))}:Mongo.sr)):Mongo.srr) with
    | {reconnect} ->
      if reconnect("send_no_reply",m)
      then snd(m,mbuf,name)
      else ML.fatal("Mongo.send({name}):","comms error (Can't reconnect)",-1)
    | {~sendresult} -> sendresult
    | _ -> @fail

  @private
  sndrcv(m,mbuf,name) =
    match Cell.call(m.conncell,({sendrecv=(m,mbuf,name)}:Mongo.sr)):Mongo.srr with
    | {reconnect} ->
      if reconnect("send_with_reply",m)
      then sndrcv(m,mbuf,name)
      else ML.fatal("Mongo.receive({name}):","comms error (Can't reconnect)",-1)
    | {~sndrcvresult} -> sndrcvresult
    | _ -> @fail

  @private
  snderr(m,mbuf,name,ns) =
    match Cell.call(m.conncell,({senderror=(m,mbuf,name,ns)}:Mongo.sr)):Mongo.srr with
    | {reconnect} ->
      if reconnect("send_with_error",m)
      then snderr(m,mbuf,name,ns)
      else ML.fatal("Mongo.snderr({name}):","comms error (Can't reconnect)",-1)
    | {~snderrresult} -> snderrresult
    | _ -> @fail

  @private
  stop(m) =
    match Cell.call(m.conncell,({stop}:Mongo.sr)):Mongo.srr with
    | {stopresult} -> void
    | _ -> @fail

  /**
   * Due to the number of parameters we have a separate [init] routine
   * from [connect].  This feature is mostly used by replica set connection
   * and re-connection.
   * Example: [init(bufsize, log)]
   * @param bufsize A hint to the driver for the initial buffer size.
   * @param log Whether to enable logging for the driver.
   **/
  init(bufsize:int, log:bool): Mongo.db =
    conn = Mutable.make({none})
    { ~conn;
      conncell=(Cell.make(conn, sr):Cell.cell(Mongo.sr,Mongo.srr));
      ~bufsize; ~log;
      seeds=[]; hosts=Mutable.make([]); name="";
      primary=Mutable.make({none}); reconnect=Mutable.make({none});
      reconnect_wait=2000; max_attempts=30; comms_timeout=3600000;
      depth=Mutable.make(0); max_depth=2;
    }

  /**
   * Connect to the MongoDB server on [host:port].
   * Close any existing connection and set primary assuming that we are a master.
   * We should really check if we are master but that would get complicated
   * since this routine gets called from within reconnect.
   * The caller should verify the master status.
   * Example: [connect(m,addr,port)]
   * @param m A [Mongo.db] value, initialised by [init].
   * @param addr Address of the MongoDB server.
   * @param port Port number for the MongoDB server.
   **/
  connect(m:Mongo.db, addr:string, port:int): outcome(Mongo.db,Mongo.failure) =
    do if m.log then ML.info("Mongo.connect","bufsize={m.bufsize} addr={addr} port={port} log={m.log}",void)
    do match m.conn.get() with | {some=conn} -> Socket.close(conn) | {none} -> void
    do m.conn.set({none})
    do m.primary.set({none})
    match Socket.connect_with_err_cont(addr,port) with
    | {success=conn} ->
       do m.conn.set({some=conn})
       do m.primary.set({some=(addr,port)})
       {success=m}
    | {failure=str} -> {failure={Error="Got exception {str}"}}

  /**
   *  Convenience function, initialise and connect at the same time.
   **/
  open(bufsize:int, addr:string, port:int, log:bool): outcome(Mongo.db,Mongo.failure) =
    connect(init(bufsize,log),addr,port)

  /**
   *  Close mongo connection.
   **/
  close(m:Mongo.db): Mongo.db =
    do if Option.is_some(m.conn.get())
       then
         do stop(m)
         Socket.close(Option.get(m.conn.get()))
    do m.conn.set({none})
    do m.primary.set({none})
    m

  /**
   * Allow the user to update with the basic communications parameters.
   **/
  set_log(m:Mongo.db, log:bool): Mongo.db = { m with ~log }
  set_reconnect_wait(m:Mongo.db, reconnect_wait:int): Mongo.db = { m with ~reconnect_wait }
  set_max_attempts(m:Mongo.db, max_attempts:int): Mongo.db = { m with ~max_attempts }
  set_comms_timeout(m:Mongo.db, comms_timeout:int): Mongo.db = { m with ~comms_timeout }

  /**
   *  Send OP_INSERT with given collection name.
   *  MongoDB doesn't send any reply.
   *  Example: [insert(m, flags, ns, document)]
   *  @param m Mongo.db value
   *  @param flags Int value with MongoDB-defined bits
   *  @param ns MongoDB namespace
   *  @param document A Bson.document value to store in the DB
   *  @return a bool indicating whether the message was successfully sent or not.
   **/
  insert(m:Mongo.db, flags:int, ns:string, documents:Bson.document): bool =
    mbuf = create_(m.bufsize)
    do insert_(mbuf,flags,ns,documents)
    snd(m,mbuf,"insert")

  /**
   * Same as insert but piggyback a getlasterror command.
   **/
  inserte(m:Mongo.db, flags:int, ns:string, dbname:string, documents:Bson.document): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do insert_(mbuf,flags,ns,documents)
    snderr(m,mbuf,"insert",dbname)

  /**
   *  [insertf]:  same as [insert] but using tags instead of bit-wise flags.
   **/
  insertf(m:Mongo.db, tags:list(Mongo.insert_tag), ns:string, documents:Bson.document): bool =
    flags = flags(List.map((t -> {itag=t}),tags))
    insert(m,flags,ns,documents)

  /**
   *  Send OP_INSERT with given collection name and multiple documents.
   *  Same parameters as for [insert].
   **/
  insert_batch(m:Mongo.db, flags:int, ns:string, documents:list(Bson.document)): bool =
    mbuf = create_(m.bufsize)
    do insert_batch_(mbuf,flags,ns,documents)
    snd(m,mbuf,"insert")

  /** insert_batch with added getlasterror query **/
  insert_batche(m:Mongo.db, flags:int, ns:string, dbname:string, documents:list(Bson.document)): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do insert_batch_(mbuf,flags,ns,documents)
    snderr(m,mbuf,"insert",dbname)

  /**
   *  [insert_batchf]:  same as [insert_batch] but using tags instead of bit-wise flags.
   **/
  insert_batchf(m:Mongo.db, tags:list(Mongo.insert_tag), ns:string, documents:list(Bson.document)): bool =
    flags = flags(List.map((t -> {itag=t}),tags))
    insert_batch(m,flags,ns,documents)

  /**
   *  Send OP_UPDATE with given collection name.
   *  Example: [update(m,flags,ns,selector,update)]
   *  Same parameters and result as for [insert] except we also
   *  provide a [select] document.
   **/
  update(m:Mongo.db, flags:int, ns:string, selector:Bson.document, update:Bson.document): bool =
    mbuf = create_(m.bufsize)
    do update_(mbuf,flags,ns,selector,update)
    snd(m,mbuf,"update")

  /** update with added getlasterror query **/
  updatee(m:Mongo.db, flags:int, ns:string, dbname:string, selector:Bson.document, update:Bson.document): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do update_(mbuf,flags,ns,selector,update)
    snderr(m,mbuf,"update",dbname)

  /**
   *  [updatef]:  same as [update] but using tags instead of bit-wise flags.
   **/
  updatef(m:Mongo.db, tags:list(Mongo.update_tag), ns:string, selector:Bson.document, update_doc:Bson.document): bool =
    flags = flags(List.map((t -> {utag=t}),tags))
    update(m,flags,ns,selector,update_doc)

  /**
   *  Send OP_QUERY and get reply.
   *  Example: [query(m, flags, ns, numberToSkip, numberToReturn, query, returnFieldSelector_opt)]
   *  @return reply The return value is an optional reply, this is an external type
   *  you need the functions in [MongoDriver], [reply_] etc. to handle this.
   **/
  query(m:Mongo.db, flags:int, ns:string, numberToSkip:int, numberToReturn:int,
        query:Bson.document, returnFieldSelector_opt:option(Bson.document)): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do query_(mbuf,flags,ns,numberToSkip,numberToReturn,query,returnFieldSelector_opt)
    sndrcv(m,mbuf,"query")

  /**
   *  [queryf]:  same as [query] but using tags instead of bit-wise flags.
   **/
  queryf(m:Mongo.db, tags:list(Mongo.query_tag), ns:string, numberToSkip:int, numberToReturn:int,
         query_doc:Bson.document, returnFieldSelector_opt:option(Bson.document)): option(Mongo.reply) =
    flags = flags(List.map((t -> {qtag=t}),tags))
    query(m,flags,ns,numberToSkip,numberToReturn,query_doc,returnFieldSelector_opt)

  /**
   *  Send OP_GETMORE and get reply.
   *  Example: [get_more(m, ns, numberToReturn, cursorID)]
   *  @param cursorID You need to get the [cursorID] from a previous reply value.
   *  @return Exactly the same as [query].
   **/
  get_more(m:Mongo.db, ns:string, numberToReturn:int, cursorID:Mongo.cursorID): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do get_more_(mbuf,ns,numberToReturn,cursorID)
    sndrcv(m,mbuf,"getmore")

  /**
   *  Send OP_DELETE.
   *  Example: [delete(m, ns, selector)]
   *  @return a bool indicating whether the message was successfully sent or not.
   **/
  delete(m:Mongo.db, flags:int, ns:string, selector:Bson.document): bool =
    mbuf = create_(m.bufsize)
    do delete_(mbuf,flags,ns,selector)
    snd(m,mbuf,"delete")

  /** delete with added getlasterror query **/
  deletee(m:Mongo.db, flags:int, ns:string, dbname:string, selector:Bson.document): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do delete_(mbuf,flags,ns,selector)
    snderr(m,mbuf,"delete",dbname)

  /**
   *  [deletef]:  same as [delete] but using tags instead of bit-wise flags.
   **/
  deletef(m:Mongo.db, tags:list(Mongo.delete_tag), ns:string, selector:Bson.document): bool =
    flags = flags(List.map((t -> {dtag=t}),tags))
    delete(m,flags,ns,selector)

  /**
   *  Send OP_KILL_CURSORS.
   *  @return a bool indicating whether the message was successfully sent or not.
   **/
  kill_cursors(m:Mongo.db, cursors:list(Mongo.cursorID)): bool =
    mbuf = create_(m.bufsize)
    do kill_cursors_(mbuf,cursors)
    snd(m,mbuf,"kill_cursors")

  /** kill_cursors with added getlasterror query **/
  kill_cursorse(m:Mongo.db, dbname:string, cursors:list(Mongo.cursorID)): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do kill_cursors_(mbuf,cursors)
    snderr(m,mbuf,"kill_cursors",dbname)

  /**
   *  Send OP_MSG.
   *  @return a bool indicating whether the message was successfully sent or not.
   **/
  msg(m:Mongo.db, msg:string): bool =
    mbuf = create_(m.bufsize)
    do msg_(mbuf,msg)
    snd(m,mbuf,"msg")

  /** kill_cursors with added getlasterror query **/
  msge(m:Mongo.db, dbname:string, msg:string): option(Mongo.reply) =
    mbuf = create_(m.bufsize)
    do msg_(mbuf,msg)
    snderr(m,mbuf,"msg",dbname)

  /** Access components of the reply value **/
  reply_messageLength = (%% BslMongo.Mongo.reply_messageLength %% : Mongo.reply -> int)
  reply_requestId = (%% BslMongo.Mongo.reply_requestId %% : Mongo.reply -> int)
  reply_responseTo = (%% BslMongo.Mongo.reply_responseTo %% : Mongo.reply -> int)
  reply_opCode = (%% BslMongo.Mongo.reply_opCode %% : Mongo.reply -> int)
  reply_responseFlags = (%% BslMongo.Mongo.reply_responseFlags %% : Mongo.reply -> int)
  reply_cursorID = (%% BslMongo.Mongo.reply_cursorID %% : Mongo.reply -> Mongo.cursorID)
  reply_startingFrom = (%% BslMongo.Mongo.reply_startingFrom %% : Mongo.reply -> int)
  reply_numberReturned = (%% BslMongo.Mongo.reply_numberReturned %% : Mongo.reply -> int)

  /** Return the n'th document attached to the reply **/
  reply_document = (%% BslMongo.Mongo.reply_document %% : Mongo.reply, int -> option(Bson.document))

  /** Debug routine, export the internal representation of the reply **/
  export_reply = (%% BslMongo.Mongo.export_reply %%: Mongo.reply -> string)

  /** Null cursor value **/
  null_cursorID = (%% BslMongo.Mongo.null_cursorID %% : void -> Mongo.cursorID)

  /** Return a string representation of a cursor (it's an int64) **/
  string_of_cursorID = (%% BslMongo.Mongo.string_of_cursorID %% : Mongo.cursorID -> string)

  /** Predicate for end of query, when the cursorID is returned as zero **/
  is_null_cursorID = (%% BslMongo.Mongo.is_null_cursorID %% : Mongo.cursorID -> bool)

  /**
   * Flags used by the index routines.
   **/
  UniqueBit     = 0x00000001
  DropDupsBit   = 0x00000002
  BackgroundBit = 0x00000004
  SparseBit     = 0x00000008

  @private create_index_(m:Mongo.db, ns:string, key:Bson.document, opts:Bson.document): bool =
    keys = Bson.keys(key)
    name = "_"^(String.concat("",keys))
    b = List.flatten([[H.doc("key",key), H.str("ns",ns), H.str("name",name)],opts])
    idxns=(match String.index(".",ns) with | {some=p} -> String.substring(0,p,ns) | {none} -> ns)^".system.indexes"
    insert(m,0,idxns,b)

  /**
   * Add an index to a collection.
   * Example: [create_index(mongo, "ns", key, flags)]
   * @param [key] is a bson object defining the fields to be indexed, eg. [\[\{Int32=("age",1)\}, \{Int32=("name",1)\}\]]
   **/
  create_index(m:Mongo.db, ns:string, key:Bson.document, options:int): bool =
    opts =
      List.flatten([(if Bitwise.land(options,UniqueBit) != 0 then [H.bool("unique",true)] else []),
                    (if Bitwise.land(options,DropDupsBit) != 0 then [H.bool("dropDups",true)] else []),
                    (if Bitwise.land(options,BackgroundBit) != 0 then [H.bool("background",true)] else []),
                    (if Bitwise.land(options,SparseBit) != 0 then [H.bool("sparse",true)] else [])])
    create_index_(m, ns, key, opts)

  /**
   * [create_indexf]:  same as [create_index] but using tags instead of bit-wise flags.
   **/
  create_indexf(m:Mongo.db, ns:string, key:Bson.document, tags:list(Mongo.index_tag)): bool =
    opts =
      List.map((t ->
                 match t with
                 | {Unique} -> H.bool("unique",true)
                 | {DropDups} -> H.bool("dropDups",true)
                 | {Background} -> H.bool("background",true)
                 | {Sparse} -> H.bool("sparse",true)),tags)
    create_index_(m, ns, key, opts)

  /**
   * Simpler version of the [create_index] function, for a single named field.
   **/
  create_simple_index(m:Mongo.db, ns:string, field:string, options:int): bool =
    create_index(m, ns, [H.i32(field,1)], options)

}}

// End of file mongo.opa
