defmodule Tracker.Plug do
  @behaviour Plug

  import Plug.Conn
  import Tracker.Utils, only: [to_scrape_path: 1]

  alias Tracker.File.Peer.Announce
  alias Tracker.File.Statistics

  def init(opts) do
    # The scrape path will be found relative to the announce path.
    # This will fail if the annonuce path is invalid
    {:ok, scrape_path} = to_scrape_path(opts[:path])

    Keyword.merge(opts, [announce: opts[:path], scrape: scrape_path])
  end

  def call(%Plug.Conn{method: "GET"} = conn, opts) do
    cond do
      conn.request_path == opts[:announce] ->
        conn |> halt |> Plug.Conn.fetch_query_params |> guard_announce

      conn.request_path == opts[:scrape] ->
        conn |> halt |> handle_scrape

      :otherwise ->
        conn
    end
  end
  # let other request methods pass through...
  def call(conn, _),
    do: conn

  #=ERROR RESPONSES=====================================================
  @error_invalid_request_data Bencode.encode!(%{
    failure_reason: "Please provide valid announce data"
  })
  @error_info_hash_not_tracked_by_server Bencode.encode!(%{
    failure_reason: "The given info_hash is not tracked by this server"
  })
  @error_failure_registering_peer Bencode.encode!(%{
    failure_reason: "Could not create peer"
  })
  @error_trackerid_must_not_be_set_on_first_announce Bencode.encode!(%{
    failure_reason: "Tracker id must not be set when announcing with started event"
  })
  @error_unknown_peer Bencode.encode!(%{
    failure_reason: "The given peer is unknown to this server"
  })
  @error_no_trackerid_specified Bencode.encode!(%{
    failure_reason: "A trackerid should always be specified unless event is set to started"
  })

  #=ANNOUNCE ===========================================================
  @default_interval 300 # five minutes

  defp guard_announce(%Plug.Conn{params: params} = conn) do
    case params do
      # ensure that all the required fields are set and valid
      %{"info_hash" => <<info_hash::binary-size(20)>>,
        "peer_id" => <<peer_id::binary-size(20)>>, "port" => port,
         "uploaded" => uploaded, "downloaded" => downloaded, "left" => left} ->
        announce = %{
          "event" => params["event"] || nil,
          "info_hash" => info_hash, "peer_id" => peer_id,
          "ip" => params["ip"] || conn.remote_ip, "port" => port,
          "uploaded" => uploaded, "downloaded" => downloaded, "left" => left,
          "trackerid" => params["trackerid"] || nil,
          "numwant" => params["numwant"] || 35,
          "compact" => params["compact"]
        }
        get_pid(conn, announce)

      _ ->
        send_resp(conn, 400, @error_invalid_request_data)
    end
  end

  # find the process needed to complete the request
  defp get_pid(conn, %{"event" => "started", "info_hash" => info_hash} = announce) do
    case :gproc.where({:n, :l, {Tracker.File, info_hash}}) do
      :undefined ->
        send_resp(conn, 404, @error_info_hash_not_tracked_by_server)

      pid ->
        handle_announce(conn, pid, announce)
    end
  end
  defp get_pid(conn, %{"trackerid" => trackerid, "info_hash" => info_hash} = announce) do
    case :gproc.where({:n, :l, {Tracker.File.Peer, info_hash, trackerid}}) do
      :undefined ->
        send_resp(conn, 404, @error_unknown_peer)

      pid ->
        handle_announce(conn, pid, announce)
    end
  end

  defp handle_announce(conn, _pid, %{"event" => "started", "info_hash" => info_hash, "trackerid" => nil} = announce) do
    case Tracker.File.Peers.add(info_hash) do
      {:ok, _peer_pid, trackerid} ->
        # send numwant (or 35) peers back
        peer_list = Announce.announce(info_hash, trackerid, announce)
        statistics = Statistics.get(info_hash)
        response_data =
          %{peers: peer_list,
            trackerid: trackerid,
            complete: statistics.complete,
            incomplete: statistics.incomplete,
            interval: @default_interval}
        case Bencode.encode(response_data) do
          {:ok, response} ->
            send_resp(conn, 201, response)

          {:error, _reason} ->
            send_resp(conn, 500, Bencode.encode!(%{"failure reason" => "Could not bencode response"}))
        end

      _ ->
        send_resp(conn, 500, @error_failure_registering_peer)
    end
  end
  defp handle_announce(conn, _pid, %{"event" => "started"}) do
    send_resp(conn, 400, @error_trackerid_must_not_be_set_on_first_announce)
  end

  # from now on `trackerid` must be present, otherwise regard it as an error
  defp handle_announce(conn, _pid, %{"trackerid" => nil}) do
    send_resp(conn, 400, @error_no_trackerid_specified)
  end

  defp handle_announce(conn, pid, %{"event" => "stopped"} = announce) do
    Tracker.Peer.announce(pid, announce)
    statistics = Statistics.get(announce["info_hash"])
    response_data =
      %{peers: [], # send zero peers back
        trackerid: announce["trackerid"],
        complete: statistics.complete,
        incomplete: statistics.incomplete,
        interval: @default_interval}
    case Bencode.encode(response_data) do
      {:ok, response} ->
        send_resp(conn, 200, response)

      {:error, _reason} ->
        send_resp(conn, 500, Bencode.encode!(%{"failure reason" => "Could not bencode response"}))
    end
  end

  defp handle_announce(conn, _pid, %{"event" => "completed", "info_hash" => info_hash, "trackerid" => trackerid} = announce) do
    # send a list of 35-50 (or numwant) peers (without seeders!) to the peer
    peer_list = Announce.announce(info_hash, trackerid, announce)
    statistics = Statistics.get(announce["info_hash"])
    response_data =
      %{peers: peer_list,
        trackerid: announce["trackerid"],
        complete: statistics.complete,
        incomplete: statistics.incomplete,
        interval: @default_interval}
    case Bencode.encode(response_data) do
      {:ok, response} ->
        send_resp(conn, 200, response)

      {:error, _reason} ->
        send_resp(conn, 500, Bencode.encode!(%{"failure reason" => "Could not bencode response"}))
    end
  end

  defp handle_announce(conn, _pid, %{"info_hash" => info_hash, "trackerid" => trackerid} = announce) do
    peer_list = Announce.announce(info_hash, trackerid, announce)
    statistics = Statistics.get(info_hash)
    # send a list of peers back
    response_data =
      %{peers: peer_list,
        trackerid: trackerid,
        complete: statistics.complete,
        incomplete: statistics.incomplete,
        interval: @default_interval}
    case Bencode.encode(response_data) do
      {:ok, response} ->
        send_resp(conn, 200, response)

      {:error, _reason} ->
        send_resp(conn, 500, Bencode.encode!(%{"failure reason" => "Could not bencode response"}))
    end

  end

  #=SCRAPE =============================================================
  defp handle_scrape(%Plug.Conn{} = conn) do
    info_hashes = get_info_hashes(conn)
    match = {{:n, :l, {Tracker.File.Statistics, :'$1'}}, :'_', :'$2'}
    result_format = [{{:'$1', :'$2'}}] # info_hash and cache value
    files =
      :gproc.select([{match, query_builder(info_hashes, :'$1'), result_format}])
      |> Stream.map(&extract_info_hash_and_value/1)
      |> Enum.into(%{})
    case Bencode.encode(%{files: files}) do
      {:ok, response} ->
        send_resp(conn, 200, response)

      {:error, _reason} ->
        send_resp(conn, 500, Bencode.encode!(%{"failure reason" => "Could not bencode response"}))
    end

  end
  # handle scrape helpers
  defp extract_info_hash_and_value({info_hash, :undefined}),
    do: {info_hash, Map.from_struct(%Statistics{})}
  defp extract_info_hash_and_value({info_hash, statistics}),
    do: {info_hash, statistics}

  # helper for building ets matchers that look for a list of info_hashes
  defp query_builder([], _),
    do: []
  defp query_builder(query, subject),
    do: [query_either(query, subject)]

  def query_either([a|[]], subject),
    do: query_equals(subject, a)
  def query_either([a|b], subject),
    do: {:or, query_equals(subject, a), query_either(b, subject)}

  def query_equals(a, b), do: {:'==', a, b}

  # Creating a custom query string parser specificly for info_hash-values,
  # as the default query parser will return a map, resulting in only the
  # last given info_hash being send as it is overwritten everytime it sees
  # a info_hash in the query_string.
  #
  # this is a problem because some clients will ask for stuff like:
  #   /scrape?info_hash=foo&info_hash=bar
  defp get_info_hashes(%Plug.Conn{} = conn) do
    conn.query_string
    |> String.split("&")
    |> Enum.filter_map(&info_hash?/1, &extract_info_hash/1)
  end

  defp info_hash?(<<"info_hash=", _::binary-size(20)>>), do: true
  defp info_hash?(_), do: false

  defp extract_info_hash(<<"info_hash=", info_hash::binary-size(20)>>),
    do: info_hash
end
