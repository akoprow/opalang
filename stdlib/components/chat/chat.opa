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
 * A generic chat component
 *
 * @category COMPONENT
 * @author Guillem Rieu, 2011
 * @destination PUBLIC
 * @stability EXPERIMENTAL
 */

import stdlib.widgets.dateprinter

/**
 * {1 About this module}
 *
 * This module is made of a generic chatting component which can be adapted to
 * multiple usages through its configuration. Default configurations covering
 * most common usages are available (non-persistent, storage of message history
 * in a DB...).
 *
 * {1 Where should I start?}
 *
 * The most basic usage, given you don't want to store messages:
 *
 * {[
 * ...
 * /* Initialize the chat session (server-side) */
 * default_chat = CChat.init(CChat.default_config)
 * ...
 * /* Build a chat box, which can then be inserted in your XHTML */
 * chatbox = CChat.create_default(default_chat, "my_nick")
 * }
 *
 * Another common usage is to store message history in a DB:
 *
 * {[
 * db /mychat : CChat.content(string, string)
 * ...
 * persistent_chat = CChat.init_persistent(CChat.default_config, @/mychat)
 * ...
 * chatbox = CChat.create_default(persistent_chat, "my_nick")
 * }
 *
 * To create a default chat box with admin rights (edit and remove messages):
 *
 * {[
 * ...
 * admin_chatbox = CChat.create_default_admin(persistent_chat, "admin")
 * ...
 * }
 *
 */

/**
 * {1 Types defined in this module}
 */

type CChat.message_id = int

type CChat.message('user, 'content) = {
  author  : 'user
  date    : Date.date
  content : 'content
}

type CChat.action('user, 'content) =
    { message : CChat.message('user, 'content); id : CChat.message_id }
  / { remove : CChat.message_id }
  / { edit   : CChat.message_id }

type CChat.server('user, 'content) = {
  register  : Network.network(CChat.action('user, 'content))
  room      : Network.network(CChat.action('user, 'content))
  requester : CChat.data_requester('user, 'content)
}

type CChat.db_path('user, 'content) = {
  ref: ref_path(CChat.content('user, 'content))
  get: CChat.message_id -> ref_path(CChat.message('user, 'content))
}

type CChat.credentials = {
  read   : bool
  edit   : bool
  remove : bool
}

/**
 * A chat instance type
 */
type CChat.instance = xhtml

/**
 * The configuration of a chat component
 */
type CChat.config('user, 'content) = {
  /** The number of past messages to display at chat creation */
  history_limit: option(int)

  /** Retrieve user rights */
  check_credentials: 'user, CChat.message('user, 'content) -> CChat.credentials

  /** Printer for user information */
  author_printer: 'user -> xhtml

  /** Printer for message content */
  message_printer: 'content -> xhtml

  /** Date printer widget configuration */
  date_printer: option(Date.date -> xhtml)

  /** Message input XHTML */
  entry_printer: CChat.display('user, 'content), ('content -> void) -> xhtml

  /** Search input */
  search_printer: option((CChat.display('user, 'content),
      ('content -> void), (-> void) -> xhtml))

  /** Search function */
  search_action: option('content -> CChat.content('user, 'content))
}

type CChat.display('user, 'content) = {
  /** If no username, assume read-only mode */
  user: option('user)

  /** History page number to display */
  history_page: int

  /** Order in which to display messages */
  reverse: bool

  /**
   * Automated scroll thresold (maximum number of pixels away from last message
   * to trigger a scroll when a new message appears). This is to avoid the user
   * to be interrupted by a new message when scrolling back the message
   * history.
   */
  max_scroll_distance: int

  /** Filter messages */
  filter: CChat.message('user, 'content) -> bool
}

type CChat.content('user, 'content) = intmap(CChat.message('user, 'content))

type CChat.data_writer('user, 'content) =
    CChat.message('user, 'content) -> void

type CChat.request('content) =
    { all }
  / { range: (int, option(int)) }
  / { query: 'content }

type CChat.data_requester('user, 'content) =
    CChat.request('content) -> CChat.content('user, 'content)

CChat = {{
/**
 * {1 Configuration}
 *
 * {2 Default config}
 *
 * With this configuration, all messages are lost between two chat sessions.
 */

  default_author_printer(author) = <>{author}</>

  default_entry_printer(_display: CChat.display, send: string -> void) =
    id = Dom.fresh_id()
    entry_input = #{entry_id(id)}
    send_action = _evt ->
      do send(Dom.get_value(entry_input))
      Dom.clear_value(entry_input)
    <>
      <input id=#{entry_id(id)} class="chat_entry" onnewline={send_action}/>
      <button class="button" onclick={send_action}>
        Post
      </button>
    </>

  default_search_printer(_display: CChat.display, id: string,
      search: (string -> void), clear: -> void) =
    search_input = #{search_id(id)}
    filter_id = filter_id(id)
    clear_search = _evt ->
      do clear()
      do Dom.clear_value(#{filter_id})
      Dom.clear_value(search_input)
    search_action = evt ->
      query = Dom.get_value(search_input)
      if query == "" then
        clear_search(evt)
      else
        do Dom.set_value(#{filter_id}, query)
        search(Dom.get_value(search_input))
    // TODO: hide the 'Clear' button when the field is empty
    <>
      <input type="text" id=#{search_id(id)} class="search_entry"
          onnewline={search_action}/>
      <input type="hidden" id=#{filter_id} />
      <button class="button" onclick={search_action}>
        Search
      </button>
      <button class="button" onclick={clear_search}>
        Clear
      </button>
    </>

  default_search_action(_query: string): CChat.content =
    // TODO: implement client-side search on non-persistent messages
    IntMap.empty

  persistent_search_action(db_path: CChat.db_path, query: string)
      : CChat.content =
    Db.intmap_search(db_path.ref, query)
      |> List.map((res -> (res, Db.read(db_path.get(res)))), _)
      |> IntMap.From.assoc_list(_)

  default_config(id: string): CChat.config(string, string) = {
    history_limit     = {some = 100}
    check_credentials = default_credentials
    author_printer    = default_author_printer
    message_printer   = Xhtml.of_string
    date_printer      = {some = create_timer}
    entry_printer     = default_entry_printer
    search_printer    = {some = default_search_printer(_, id, _, _)}
    search_action     = {some = default_search_action}
  }

  persistent_config(id, db_path): CChat.config(string, string) = {
    default_config(id) with
    search_action = {some = persistent_search_action(db_path, _)}
  }

  default_filter(id: string): CChat.message -> bool =
      @sliced_expr({
        client = message ->
          filter_word = Dom.get_value(#{filter_id(id)})
          do jlog("filter_word (id = {id}) = {filter_word}")
          if String.length(filter_word) == 0 then
            {true}
          else
            match String.index(filter_word, message.content) with
              | {none} -> {false}
              | {some=_} -> {true}

        server = _ -> {true}})

  default_display(id, username): CChat.display(string, string) = {
    user                = {some = username}
    history_page        = 0
    reverse             = true
    filter              = default_filter(id)
    max_scroll_distance = 100
  }

/**
 * {1 High-level interface}
 */

  /**
   * An empty chat box content
   */
  empty: CChat.content = IntMap.empty

  dummy_requester(_) = CChat.empty

  /**
   * Initialize a new chat session
   *
   * @param config A CChat configuration
   * @return A chat session instance
   */
  init(_config: CChat.config('user, 'content))
      : CChat.server('user, 'content) =
    net = Network.empty()
    {
      register  = net
      room      = net
      requester = dummy_requester
    }

  /**
   * Initialize a new persistent chat session
   *
   * @param config A CChat configuration
   * @param db_path The DB reference path where to store messages
   * @return A persistent chat session instance
   */
  init_persistent(config: CChat.config('user, 'content),
      db_path: CChat.db_path('user, 'content))
      : CChat.server('user, 'content) =

    /* Add a fresh DB key to a message */
    set_key(action: CChat.action): CChat.action = match action with
      | { ~message id=_ } ->
        key = Db.fresh_key(db_path.ref)
        { ~message id=key }
      | any -> any

    /* Data writer */
    db_writer(action: CChat.action): void = match action with
      | { ~message ~id } ->
        Db.write(db_path.get(id), message)
      | { edit=_edit } ->
        void
      | { remove = key } ->
        Db.remove(db_path.get(key))

    /* Data requester */
    db_reader(request: CChat.request): CChat.content =
      search_action = config.search_action ? (_ -> CChat.empty)
      content = Db.read(db_path.ref)
      match request with
      | { all } ->
        content
      | { range = (start, ending) } ->
        size = IntMap.size(content)
        real_ending = ending ? size
        IntMap.To.assoc_list(content)
          |> List.drop(size - real_ending, _)
          |> List.take(size - start, _)
          |> IntMap.From.assoc_list(_)
      | { ~query } ->
        search_action(query)

    /* Chat room and associated observer */
    llchat_room = Network.empty()
    _ = Network.observe(db_writer, llchat_room)
    chat_room = Network.map(set_key, llchat_room)

    /* CChat server instance */
    { register = llchat_room; room = chat_room; requester = db_reader }

  /**
   * Create a chat box with default parameters (user information and message
   * content are both assumed to be of type strings)
   *
   * @param server The chat session to use
   * @param username The nickname to display in the chat
   * @return The XHTML corresponding to the chat box
   */
  create_default(server: CChat.server, username: string)
      : CChat.instance =
    id = Random.string(8)
    config = default_config(id)
    initial_content = server.requester({ range = (0, config.history_limit) })
    create(config, server, id, default_display(id, username),
        initial_content, ignore)

  /**
   * Create a chat box with admin rights
   */
  create_default_admin(server: CChat.server, username: string)
      : CChat.instance =
    id = Random.string(8)
    config = {default_config(id) with
      check_credentials = default_admin_credentials
    }
    initial_content = server.requester({ range = (0, config.history_limit) })
    create(config, server, id, default_display(id, username),
        initial_content, ignore)

  /**
   * Generic function to build a chat box
   *
   * @param config The configuration of the chat box
   * @param server The instance of the chat session
   * @param id The ID in which the chat box will be inserted
   * @param initial_display The initial display parameters
   * @param initial_content The initial messages to display
   * @param data_writer Function called when a new message is sent
   * @param data_requester Function retrieving existing messages
   * @return The XHTML corresponding to the chat box
   */
  create(config: CChat.config, server: CChat.server, id: string,
      initial_display: CChat.display, initial_content: CChat.content,
      data_writer: CChat.data_writer)
      : CChat.instance =
    author = initial_display.user
        ? error("CChat: guest mode not yet implemented")
    do_request(req) =
      results = server.requester(req)
      if IntMap.is_empty(results) then
        Dom.transform([#{conversation_id(id)} <-
          <span class="error_noresult">No message found.</span>])
      else
        Dom.transform([#{conversation_id(id)} <-
          content_xhtml(config, id, author, initial_display, results, server)])
    do_search(query) = do_request({ ~query })
    do_clear() = do_request({ range = (0, config.history_limit) })
    conversation_box =
      (<a onready={_ ->
          Network.add_callback(
              user_update(config, id, initial_display, author, server, _),
                  server.register)}/>
      <div id=#{conversation_id(id)} class="chat_conversation"
          style={css {overflow: auto;}}>
        {content_xhtml(config, id, author, initial_display, initial_content,
            server)}
      </div>)
    search_box =
      match config.search_printer with
      | {none} -> <></>
      | {some=print_search} ->
      (<div class="search_container">
        {print_search(initial_display, do_search, do_clear)}
      </div>)
    entry_box =
      (<div class="entry_container">
        {config.entry_printer(initial_display,
            send_message(id, server, data_writer, author, _))}
      </div>)
    chat_elements = [conversation_box, entry_box, search_box]
    <>
      {if initial_display.reverse then List.rev(chat_elements)
      else chat_elements}
    </>

/**
 * {2 Common credential sets}
 */

  read_only = {read = true; edit = false; remove = false}
  read_edit = {read = true; edit = true; remove = false}
  read_edit_remove = {read = true; edit = true; remove = true}

/*
 * {1 Private functions}
 */


  @private
  duration_printer_fmt =
    "[%>:[%D:[#=1:tomorrow :in ]]]" ^
    "[%Y:[#>0:# year[#>1:s] ][#=0:" ^
    "[%M:[#>0:# month[#>1:s] ][#=0:" ^
    "[%D:[#>1:# day[#>1:s] ][#=0:" ^
    "[%h:[#>0:# hour[#>1:s] ][#=0:" ^
    "[%m:[#>0:# minute[#>1:s] ][#=0:" ^
    "[%s:a few seconds " ^
    /*"[%s:[#>0:# second[#>1:s] :now ]" ^*/
    "]]]]]]]]]]]" ^
    "[%<:[%D:[#=1:yesterday :ago ]]]"

  @private @server
  default_credentials(_username, _msg): CChat.credentials = read_only

  @private @server
  default_admin_credentials(_username, _msg): CChat.credentials =
    read_edit_remove

  @private entry_id(id): string = "{id}_entry"
  @private search_id(id): string = "{id}_search"
  @private filter_id(id): string = "{id}_filter"
  @private conversation_id(id): string = "{id}_conversation"
  @private message_id(id, msg_id): string = "{id}_message_{msg_id}"

  @private
  create_timer(date: Date.date): xhtml =
    dp_id = Random.string(8)
    container_id = Random.string(8)
    <div id={container_id} onready={_ ->
        dp_config = {WDatePrinter.default_config with
          duration_printer = Duration.generate_printer(duration_printer_fmt)
        }
        Dom.transform([#{container_id} <-
            WDatePrinter.html(dp_config, dp_id, date)])
      }></div>

  @private
  actions_of_credentials({read=_ edit=_ ~remove}: CChat.credentials,
      msg_id, _msg, server): xhtml =
      /*{if edit then <button class="chat_edit">Edit</button> else <></>}*/
    <>
      {if remove then
        <button onclick={_evt -> remove_message(msg_id, server)} class="chat_remove">
          Remove
        </button>
      else <></>}
    </>

  @private
  message_xhtml(config, id, user, msg_id, msg, server): xhtml =
    creds = config.check_credentials(user, msg)
    if creds.read then
      dp_xhtml = match config.date_printer with
        | {none} -> <></>
        | {~some} -> some(msg.date)
      edit_xhtml = actions_of_credentials(creds, msg_id, msg, server)
      <div id={message_id(id, msg_id)} class="chat_line">
        <div class="chat_author">{config.author_printer(msg.author)}</div>
        <div class="chat_message">{config.message_printer(msg.content)}</div>
        <div class="chat_date">{dp_xhtml}</div>
        <div class="chat_actions">{edit_xhtml}</div>
      </div>
    else
      <></>

  @private
  content_xhtml(config: CChat.config, id, user, display: CChat.display,
      content: CChat.content, server): xhtml =
    fold = if display.reverse then IntMap.rev_fold else IntMap.fold
    aux(key, msg, acc) =
      acc <+>
        if display.filter(msg) then
          message_xhtml(config, id, user, key, msg, server)
        else
          <></>
    fold(aux, content, <></>)

  @private @client
  user_update(config: CChat.config, id, display: CChat.display,
      user, server, action): void =
    match action with
      | { ~message id=msg_id } ->
        /*if display.filter(message) then*/
          msg_xhtml = message_xhtml(config, id, user, msg_id, message, server)
          conv_id = conversation_id(id)
          funaction =
            if display.reverse then [#{conv_id} -<- msg_xhtml]
            else [#{conv_id} +<- msg_xhtml]
          actual_scroll = Dom.get_scroll(#{conv_id})
          max_scroll = Dom.get_scrollable_size(#{conv_id})
          do_scroll =
            if display.reverse
              && (actual_scroll.y_px < display.max_scroll_distance)
            then
              Dom.scroll_to_top
            else if not(display.reverse)
              && (max_scroll.y_px - actual_scroll.y_px)
              < display.max_scroll_distance
            then
              Dom.scroll_to_bottom
            else
              (_ -> void)
          do Dom.transform(funaction)
          do_scroll(#{conversation_id(id)})
      | { ~remove } ->
        Dom.remove(#{message_id(id, remove)})
      | { edit = _edit } -> void

  /** Retrieve entered text and broadcast it */
  @private
  send_message(_id, server, data_writer, author, content): void =
    if content != "" then
      new_message = {~author; ~content; date = Date.now()}
      _ = data_writer(new_message)
      Network.broadcast({ id = -1; message = new_message }, server.room)

  @private
  remove_message(msg_id, server): void =
    Network.broadcast({ remove = msg_id }, server.room)
}}