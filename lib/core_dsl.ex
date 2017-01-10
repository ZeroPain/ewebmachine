defmodule Ewebmachine.Core.DSL do
  ## Macros and helpers defining the DSL for the Ewebmachine decision
  ## core : for legacy reasons, the module is called 'DSL' while they are
  ## are mostly helper functions.
  ##
  ## Changes:
  ##     Macros hiding `conn` and `user_state` variables have been removed
  ##     as they can produce unsafe use of these variables if used in
  ##     structures like if/cond/... which is deprecated in elixir 1.3

  ## Usage : 

  ##     decision mydecision(conn, user_state, args...) do # def mydecision(conn, user_state, arg...)
  ##       ...debug_decision
  ##       ...exec body
  ##     end
  @moduledoc false

  alias Plug.Conn

  defmacro __using__(_opts) do quote do
    import Ewebmachine.Core.DSL
    import Ewebmachine.Core.Utils
  end end

  def sig_to_sigwhen({:when, _, [{name,_,params}, guard]}), do: {name, params, guard}
  def sig_to_sigwhen({name, _, params}) when is_list(params), do: {name, params, true}
  def sig_to_sigwhen({name, _, _}), do: {name, [], true}

  defmacro decision(sig, do: body) do
    {name, [conn, state], guard} = sig_to_sigwhen(sig)
    quote do
      def unquote(name)(unquote(conn), unquote(state)) when unquote(guard) do
        var!(conn) = Ewebmachine.Log.debug_decision(unquote(conn), unquote(name))
        unquote(body)
      end
    end
  end

  def resource_call(conn, state, fun) do
    handler = conn.private[:resource_handlers][fun] || Ewebmachine.Handlers
    {reply, conn, state} = term = apply(handler, fun, [conn, state])
    conn = Ewebmachine.Log.debug_call(conn, handler, fun, [conn, state], term)
    case reply do
      {:halt, code} ->
	throw {:halt, set_response_code(conn, code)}
      _ ->
	{reply, conn, state}
    end
  end

  def method(conn), do: conn.method

  def resp_redirect(conn), do: conn.private[:resp_redirect]

  def get_resp_header(conn, name), do: first_or_nil(Conn.get_resp_header(conn, name))

  def path(conn), do: conn.request_path

  def get_header_val(conn, name), do: first_or_nil(Conn.get_req_header(conn, name))

  def set_response_code(conn, code) do
    conn = conn # halt machine when set response code, on respond
    |> Conn.put_status(code)
    |> Ewebmachine.Log.debug_enddecision
    conn = if !conn.resp_body, do: %{conn | resp_body: ""}, else: conn
    %{conn | state: :set}
  end

  def set_resp_header(conn, k, v), do: Conn.put_resp_header(conn, k, v)
  
  def set_resp_headers(conn, kvs) do
    Enum.reduce(kvs, conn,
      fn {k,v}, acc ->
	Conn.put_resp_header(acc, k, v)
      end)
  end

  def remove_resp_header(conn, k) do
    Conn.delete_resp_header(conn, k)
  end

  def set_disp_path(conn, path), do: %{conn | script_name: String.split("#{path}","/")}

  def resp_body(conn), do: conn.private[:machine_body_stream] || conn.resp_body

  def set_resp_body(conn, body) when is_binary(body) or is_list(body) do
    %{conn | resp_body: body}
  end
  def set_resp_body(conn, body) do          #if not an IO List, then it should be an enumerable
    Conn.put_private(conn, :machine_body_stream, body)
  end

  def has_resp_body(conn) do
    (!is_nil(conn.resp_body) or !is_nil(conn.private[:machine_body_stream]))
  end
  
  def get_metadata(conn, key), do: conn.private[key]

  def set_metadata(conn, k, v), do: Conn.put_private(conn, k, v)
  
  def compute_body_md5(conn) do
    conn = Ewebmachine.fetch_req_body(conn, [])
    :crypto.hash(:md5, Ewebmachine.req_body(conn))
  end

  def first_or_nil([v|_]), do: v
  def first_or_nil(_), do: nil
end

defmodule Ewebmachine.Core.Utils do
  @moduledoc "HTTP utility module"

  @type norm_content_type :: {type::String.t,subtype::String.t,params::map}

  @doc "convert any content type representation (see spec) into a `norm_content_type`"
  @spec normalize_mtype({type::String.t,params::map} | type::String.t | norm_content_type) :: norm_content_type
  def normalize_mtype({type,params}) do
    case String.split(type,"/") do
      [type,subtype]->{type,subtype,params}
      _->{"application","octet-stream",%{}}
    end
  end
  def normalize_mtype({_,_,%{}}=mtype), do: mtype
  def normalize_mtype(type) do
    case Plug.Conn.Utils.media_type(to_string(type)) do
      {:ok,type,subtype,params}->{type,subtype,params}
      :error-> {"application","octet-stream",%{}}
    end
  end

  @doc "Match normalized media types accepting a partial match (wildcard or
  incomplete params)"
  def fuzzy_mt_match({h_type,h_subtype,h_params},{a_type,a_subtype,a_params}) do
    (a_type == h_type or a_type == "*" ) and 
      (a_subtype == h_subtype or a_subtype=="*") and 
      Enum.all?(a_params, fn {k,v}-> h_params[k] == v end)
  end

  @doc "format a `norm_content_type` into an HTTP content type header"
  @spec format_mtype(norm_content_type) :: String.t
  def format_mtype({type,subtype,params}) do
    params = params |> Enum.map(fn {k,v}->"; #{k}=#{v}" end) |> Enum.join
    "#{type}/#{subtype}#{params}"
  end

  @doc """
  HTTP Content negociation, get the content type to send from : 

  - `accept_header`, the HTTP header `Accept`
  - `ct_provided`, the list of provided content types
  """
  @spec choose_media_type([norm_content_type],String.t) :: norm_content_type
  def choose_media_type(ct_provided,accept_header) do
    accepts = accept_header |> Plug.Conn.Utils.list |> Enum.map(fn "*"->"*/*";e->e end) |>  Enum.map(&Plug.Conn.Utils.media_type/1)
    accepts = for {:ok,type,subtype,params}<-accepts do 
      q = case Float.parse(params["q"] || "1") do {q,_}->q ; _ -> 1 end
      {q,type,subtype,Dict.delete(params,"q")}
    end |> Enum.sort |> Enum.reverse
    Enum.find_value(accepts,fn {_,atype,asubtype,aparams}->
      Enum.find(ct_provided, fn {type,subtype,params}->
        (atype=="*" or atype==type) and (asubtype=="*" or asubtype==subtype) and aparams==params
      end)
    end)
  end

  @doc "Remove quotes from HTTP quoted string"
  def quoted_string(value), do: 
    Plug.Conn.Utils.token(value)
  @doc "Get the string list from a comma separated list of HTTP quoted strings"
  def split_quoted_strings(str), do:
    (str |> Plug.Conn.Utils.list |> Enum.map(&Plug.Conn.Utils.token/1))

  @doc "Convert a calendar date to a rfc1123 date string"
  @spec rfc1123_date({{year::integer,month::integer,day::integer}, {h::integer, min::integer, sec::integer}}) :: String.t
  def rfc1123_date({{yyyy, mm, dd}, {hour, min, sec}}) do
    day_number = :calendar.day_of_the_week({yyyy, mm, dd})
    :io_lib.format('~s, ~2.2.0w ~3.s ~4.4.0w ~2.2.0w:~2.2.0w:~2.2.0w GMT',
                     [:httpd_util.day(day_number), dd, :httpd_util.month(mm),
                      yyyy, hour, min, sec]) |> IO.iodata_to_binary
  end

  @doc "Convert rfc1123 or rfc850 to :calendar dates"
  @spec convert_request_date(String.t) :: {{year::integer,month::integer,day::integer}, {h::integer, min::integer, sec::integer}}
  def convert_request_date(date) do
    try do :httpd_util.convert_request_date('#{date}') catch _,_ -> :bad_date end
  end

  @doc """
  HTTP Encoding negociation, get the encoding to use from : 

  - `acc_enc_hdr`, the HTTP header `Accept-Encoding`
  - `encs`, the list of supported encoding
  """
  @spec choose_encoding([String.t],String.t) :: String.t
  def choose_encoding(encs,acc_enc_hdr), do:
    choose(encs,acc_enc_hdr,"identity")

  @doc """
  HTTP Charset negociation, get the charset to use from : 

  - `acc_char_hdr`, the HTTP header `Accept-Charset`
  - `charsets`, the list of supported charsets
  """
  @spec choose_charset([String.t],String.t) :: String.t
  def choose_charset(charsets,acc_char_hdr), do:
    choose(charsets,acc_char_hdr,"utf8")

  defp choose(choices,header,default) do
    ## sorted set of {prio,value}
    prios = prioritized_values(header)

    # determine if default is ok or any is ok if no match
    default_prio = Enum.find_value(prios, fn {prio,v}-> v==default && prio end)
    start_prio = Enum.find_value(prios, fn {prio,v}-> v=="*" && prio end)
    default_ok = case default_prio do
      nil -> start_prio !== 0.0
      0.0 -> false
      _ -> true
    end
    any_ok = not start_prio in [nil,0.0]

    # remove choices where prio == 0.0
    {zero_prios,prios} = Enum.partition(prios,fn {prio,_}-> prio == 0.0 end)
    choices_to_remove = Enum.map(zero_prios,&elem(&1,1))
    choices = Enum.filter(choices,&!(String.downcase(&1) in choices_to_remove))

    # find first match, if not found and any_ok, then first choice, else if default_ok, take it
    if choices !== [] do
      Enum.find_value(prios, fn {_,val}->
        Enum.find(choices, &(val == String.downcase(&1)))
      end) ||
        (any_ok && hd(choices) || 
          (default_ok && Enum.find(choices,&(&1 == default)) || 
            nil))
    end
  end

  defp prioritized_values(header) do
    header 
    |> Plug.Conn.Utils.list
    |> Enum.map(fn e->
        {q,v} = case String.split(e,~r"\s;\s", parts: 2) do
          [value,params] ->
             case Float.parse(Plug.Conn.Utils.params(params)["q"] || "1.0") do
               {q,_}->{q,value}
               :error -> {1.0,value}
             end
          [value] -> {1.0,value}
        end
        {q,String.downcase(v)}
      end)
    |> Enum.sort
    |> Enum.reverse
  end

  @doc "get HTTP status label from HTTP code"
  @spec http_label(code :: integer) :: String.t
  def http_label(100), do: "Continue"
  def http_label(101), do: "Switching Protocol"
  def http_label(200), do: "OK"
  def http_label(201), do: "Created"
  def http_label(202), do: "Accepted"
  def http_label(203), do: "Non-Authoritative Information"
  def http_label(204), do: "No Content"
  def http_label(205), do: "Reset Content"
  def http_label(206), do: "Partial Content"
  def http_label(300), do: "Multiple Choice"
  def http_label(301), do: "Moved Permanently"
  def http_label(302), do: "Found"
  def http_label(303), do: "See Other"
  def http_label(304), do: "Not Modified"
  def http_label(305), do: "Use Proxy"
  def http_label(306), do: "unused"
  def http_label(307), do: "Temporary Redirect"
  def http_label(308), do: "Permanent Redirect"
  def http_label(400), do: "Bad Request"
  def http_label(401), do: "Unauthorized"
  def http_label(402), do: "Payment Required"
  def http_label(403), do: "Forbidden"
  def http_label(404), do: "Not Found"
  def http_label(405), do: "Method Not Allowed"
  def http_label(406), do: "Not Acceptable"
  def http_label(407), do: "Proxy Authentication Required"
  def http_label(408), do: "Request Timeout"
  def http_label(409), do: "Conflict"
  def http_label(410), do: "Gone"
  def http_label(411), do: "Length Required"
  def http_label(412), do: "Precondition Failed"
  def http_label(413), do: "Request Entity Too Large"
  def http_label(414), do: "Request-URI Too Long"
  def http_label(415), do: "Unsupported Media Type"
  def http_label(416), do: "Requested Range Not Satisfiable"
  def http_label(417), do: "Expectation Failed"
  def http_label(500), do: "Internal Server Error"
  def http_label(501), do: "Not Implemented"
  def http_label(502), do: "Bad Gateway"
  def http_label(503), do: "Service Unavailable"
  def http_label(504), do: "Gateway Timeout"
  def http_label(505), do: "HTTP Version Not Supported"
end
