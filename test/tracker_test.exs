defmodule TrackerTest do
  use ExUnit.Case
  doctest Tracker

  setup do
    {:ok, pid} = Tracker.start(:normal, [])
    on_exit(fn ->
      if (Process.alive?(pid)), do: Process.exit(pid, :normal)
      :timer.sleep 10
    end)
    :ok
  end

  test "tracking a new file" do
    info_hash = "xxxxxxxxxxxxxxxxxxxx"
    Tracker.File.create(info_hash)
    # adding a new file should spawn an info-, statistics-, and peer supervisor-process
    assert {_pid, _} = :gproc.await({:n, :l, {Tracker.File.Info, info_hash}}, 200)
    assert {_pid, _} = :gproc.await({:n, :l, {Tracker.File.Statistics, info_hash}}, 200)
    assert {_pid, _} = :gproc.await({:n, :l, {Tracker.File.Peers, info_hash}}, 200)
  end

  test "should return the same pid when registering the same info_hash twice (or more)" do
    info_hash = "xxxxxxxxxxxxxxxxxxxx"
    Tracker.File.create(info_hash)
    {pid, _} = :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)
    assert {:ok, ^pid} = Tracker.File.create(info_hash)
  end

  test "creating a peer should return the trackerid" do
    info_hash = "yyyyyyyyyyyyyyyyyyyy"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File.Peers, info_hash}}, 200)

    {:ok, pid, trackerid} = Tracker.File.Peers.add(info_hash)
    assert {^pid, _} = :gproc.await({:n, :l, {Tracker.File.Peer, info_hash, trackerid}}, 200)
  end

  test "creating multiple peers should different trackerids" do
    info_hash = "yyyyyyyyyyyyyyyyyyyy"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File.Peers, info_hash}}, 200)

    {:ok, _pid, trackerid} = Tracker.File.Peers.add(info_hash)
    {:ok, _pid, trackerid2} = Tracker.File.Peers.add(info_hash)
    refute trackerid == trackerid2
  end

  # Removing a torrent =================================================
  test "should remove all peers when shutting down on purpose" do
    info_hash = "01234567890123456789"
    Tracker.File.create(info_hash)
    {file_pid, _} = :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)

    {:ok, _pid, trackerid} = Tracker.File.Peers.add(info_hash)
    {:ok, _pid, trackerid2} = Tracker.File.Peers.add(info_hash)

    {peer_pid1, _} = :gproc.await({:n, :l, {Tracker.File.Peer, info_hash, trackerid}})
    {peer_pid2, _} = :gproc.await({:n, :l, {Tracker.File.Peer, info_hash, trackerid2}})

    assert Process.alive?(file_pid)
    assert Process.alive?(peer_pid1)
    assert Process.alive?(peer_pid2)

    Tracker.File.remove(info_hash)

    refute Process.alive?(file_pid)
    refute Process.alive?(peer_pid1)
    refute Process.alive?(peer_pid2)
  end

  # Statistics =========================================================
  test "statistics on a tracked file" do
    info_hash = "23456789012345678901"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)
    expected = %Tracker.File.Statistics{downloaded: 0, incomplete: 0, complete: 0}
    assert expected == Tracker.File.Statistics.get(info_hash)
  end

  # peer joining -------------------------------------------------------
  test "should update incomplete statistics when a new peer joins" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)
    {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
    announce_data =
      %{"event" => "started",
        "ip" => {127, 0, 0, 1},
        "port" => 12345,
        "peer_id" => "xxxxxxxxxxxxxxxxxxxx"}
    Tracker.File.Peer.Announce.announce(info_hash, trackerid, announce_data)
    expected = %Tracker.File.Statistics{downloaded: 0, incomplete: 1, complete: 0}
    assert expected == Tracker.File.Statistics.get(info_hash)
  end
  # test "should not increment 'downloads' when a peer joins and announce 0 left"

  # peer completing ----------------------------------------------------
  test "increment complete and download, and decrement incomplete statistics when a peer complete" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)
    {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
    announce_data =
      %{"event" => "started",
        "left" => 1,
        "downloaded" => 1,
        "uploaded" => 1,
        "ip" => {127, 0, 0, 1},
        "port" => 12345,
        "peer_id" => "xxxxxxxxxxxxxxxxxxxx"}
    Tracker.File.Peer.Announce.announce(info_hash, trackerid, announce_data)

    announce_data =
      %{"event" => "completed", "left" => 1, "downloaded" => 1, "uploaded" => 1,
        "ip" => {127, 0, 0, 1},
        "port" => 12345,
        "peer_id" => "xxxxxxxxxxxxxxxxxxxx"}

    Tracker.File.Peer.Announce.announce(info_hash, trackerid, announce_data)
    expected = %Tracker.File.Statistics{incomplete: 0, complete: 1, downloaded: 1}
    assert expected == Tracker.File.Statistics.get(info_hash)
  end

  # peer stopping ------------------------------------------------------
  test "should decrement its incomplete statistics when an incomplete peer stops" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)
    {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
    announce_data =
      %{"event" => "started",
        "ip" => {127, 0, 0, 1},
        "port" => 12345,
        "peer_id" => "xxxxxxxxxxxxxxxxxxxx"}
    Tracker.File.Peer.Announce.announce(info_hash, trackerid, announce_data)

    announce_data =
      %{"event" => "stopped",
        "ip" => {127, 0, 0, 1},
        "port" => 12345,
        "peer_id" => "xxxxxxxxxxxxxxxxxxxx"}
    Tracker.File.Peer.Announce.announce(info_hash, trackerid, announce_data)

    expected = %Tracker.File.Statistics{incomplete: 0, complete: 0, downloaded: 0}
    assert expected == Tracker.File.Statistics.get(info_hash)
  end

  test "should decrement its complete statistics when a complete peer stops" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)
    {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
    announce_data = %{"ip" => {127, 0, 0, 1},
             "port" => 12345,
             "peer_id" => "xxxxxxxxxxxxxxxxxxxx"}
    for event <- ["started", "completed", "stopped"] do
      peer_data = Map.merge(announce_data, %{"event" => event})
      Tracker.File.Peer.Announce.announce(info_hash, trackerid, peer_data)
    end

    expected = %Tracker.File.Statistics{incomplete: 0, complete: 0, downloaded: 1}
    assert expected == Tracker.File.Statistics.get(info_hash)
  end

  test "peer should be removed from the registry when removed" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)
    {:ok, pid, trackerid} = Tracker.File.Peers.add(info_hash)
    announce_data =
      %{"ip" => {127, 0, 0, 1},
        "port" => 12345,
        "peer_id" => "xxxxxxxxxxxxxxxxxxxx"}
    # start peer
    peer_data = Map.merge(announce_data, %{"event" => "started"})
    Tracker.File.Peer.Announce.announce(info_hash, trackerid, peer_data)

    assert Process.alive?(pid)
    Tracker.File.Peers.remove(info_hash, trackerid)
    refute Process.alive?(pid)
  end

  # Randomly killing a new torrent =====================================
  # test "when killed it should respawn and collect data from the peers"

  # peer dissapearing/timing out ---------------------------------------
  # test "should decrement its incomplete statistics when an incomplete peer times out"
  # test "should decrement its complete statistics when a complete peer times out"

  test "state should store uploaded/downloaded/left" do
    info_hash = "xxxxxxxxxxxxxxxxxxxx"
    trackerid = "yyyyyyyyyyyyyyyyyyyy"
    opts = [info_hash: info_hash, trackerid: trackerid]

    Tracker.File.Peer.State.start_link(opts)
    update_data = %{"uploaded" => "10", "left" => "200", "downloaded" => "39"}
    assert Tracker.File.Peer.State.update(info_hash, trackerid, update_data) == :ok
    expected = %Tracker.File.Peer.State{uploaded: "10", left: "200", downloaded: "39"}
    assert Tracker.File.Peer.State.get(info_hash, trackerid) == expected
  end

  test "announce should be send back an empty list of peers if no other peers are present" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)

    # add two peers
    {:ok, _pid, trackerid} = Tracker.File.Peers.add(info_hash)
    data =
      %{"peer_id" => "xxxxxxxxxxxxxxxxxxxx",
        "event" => "started",
        "ip" => {127, 0, 0, 1}, "port" => 12345}
    announce = Tracker.File.Peer.Announce.announce(info_hash, trackerid, data)

    assert announce == []
  end

  test "announce should be send back a list of peers" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)

    # add two peers
    data =
      %{"peer_id" => "xxxxxxxxxxxxxxxxxxxx",
        "event" => "started",
        "ip" => {127, 0, 0, 1}, "port" => 12345}
    for port <- [12346, 12347] do
      {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
      peer_data = Map.merge(data, %{"port" => port})
      Tracker.File.Peer.Announce.announce(info_hash, trackerid, peer_data)
    end
    {:ok, _pid, trackerid} = Tracker.File.Peers.add(info_hash)
    announce = Tracker.File.Peer.Announce.announce(info_hash, trackerid, data)

    ports = announce |> Enum.map(&(&1[:port])) |> Enum.sort
    assert ports == [12346, 12347]
  end

  test "a completed peer should only get incomplete peers back when announcing" do
    info_hash = "xxxxxxxxxxxxxxxxxxxx"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)

    data =
      %{"peer_id" => "xxxxxxxxxxxxxxxxxxxx",
        "event" => "started",
        "ip" => {127, 0, 0, 1}, "port" => 12345}
    peers = for port <- [12346, 12347] do
      {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
      peer_data = Map.merge(data, %{"port" => port})
      Tracker.File.Peer.Announce.announce(info_hash, trackerid, peer_data)
      trackerid
    end

    # complete one of the peers, there should only be one incomplete peer left
    Tracker.File.Peer.Announce.announce(info_hash, hd(peers), Map.merge(data, %{"event" => "completed"}))
    # start a new peer, complete it and ask for peers
    {:ok, _pid, trackerid} = Tracker.File.Peers.add(info_hash)
    Tracker.File.Peer.Announce.announce(info_hash, trackerid, data)
    Tracker.File.Peer.Announce.announce(info_hash, trackerid, Map.merge(data, %{"event" => "completed"}))

    result = length Tracker.File.Peer.Announce.announce(info_hash, trackerid, Map.delete(data, "event"))
    assert result == 1
  end

  test "announce should be send back a list of peers without peer ids if no_peer_ids are specified" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)

    # add two peers
    data =
      %{"peer_id" => "xxxxxxxxxxxxxxxxxxxx",
        "event" => "started",
        "ip" => {127, 0, 0, 1}, "port" => 12345}
    for port <- [12346, 12347] do
      {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
      peer_data = Map.merge(data, %{"port" => port})
      Tracker.File.Peer.Announce.announce(info_hash, trackerid, peer_data)
    end
    {:ok, _pid, trackerid} = Tracker.File.Peers.add(info_hash)
    announce = Tracker.File.Peer.Announce.announce(info_hash, trackerid, Map.put(data, "no_peer_id", 1))

    refute Enum.any?(announce, &(Map.has_key?(&1, :peer_id)))
  end

  test "announce should be send back a list of peers in compact notation if specified" do
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)

    # add two peers
    data =
      %{"peer_id" => "xxxxxxxxxxxxxxxxxxxx",
        "event" => "started",
        "ip" => {127, 0, 0, 1}, "port" => 12345}
    for port <- [12346, 12347] do
      {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
      peer_data = Map.merge(data, %{"port" => port})
      Tracker.File.Peer.Announce.announce(info_hash, trackerid, peer_data)
    end
    {:ok, _pid, trackerid} = Tracker.File.Peers.add(info_hash)
    announce = Tracker.File.Peer.Announce.announce(info_hash, trackerid, Map.put(data, "compact", 1))

    result = String.split_at(announce, 6) |> Tuple.to_list
    assert <<127, 0, 0, 1, 48, 58>> in result
    assert <<127, 0, 0, 1, 48, 59>> in result
  end

  test "a peer should be able to switch ip and port if key is provided during announce" do
    alias Tracker.File.Peer.Announce
    info_hash = "12345678901234567890"
    Tracker.File.create(info_hash)
    :gproc.await({:n, :l, {Tracker.File, info_hash}}, 200)

    # create two peers and change the ip and port of the one and check with the other
    data = %{"peer_id" => "xxxxxxxxxxxxxxxxxxxx", "ip" => {127, 0, 0, 1}}
    [peer1, peer2] = for port <- [12345, 12346] do
      {:ok, _, trackerid} = Tracker.File.Peers.add(info_hash)
      %{ip: data["ip"], port: port, trackerid: trackerid}
    end

    start_data = Map.put(data, "event", "started")
    Announce.announce(info_hash, peer1.trackerid, Map.merge(start_data,
                                                            %{"key" => "foo",
                                                              "port" => peer1.port}))
    result = Announce.announce(info_hash, peer2.trackerid, Map.merge(start_data,
                                                                     %{"port" => peer2.port,
                                                                       "compact" => 1}))
    assert result == <<127, 0, 0, 1, 48, 57>>

    Announce.announce(info_hash, peer1.trackerid, Map.merge(start_data,
      %{"key" => "foo", "port" => peer1.port + 1, "ip" => {127, 0, 0, 2}}))
    result = Announce.announce(info_hash, peer2.trackerid, Map.merge(start_data,
                                                                     %{"port" => peer2.port,
                                                                       "compact" => 1}))
    assert result == <<127, 0, 0, 2, 48, 58>>
  end

end
