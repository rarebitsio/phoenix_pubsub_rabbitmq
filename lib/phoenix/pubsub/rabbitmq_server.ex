defmodule Phoenix.PubSub.RabbitMQServer do
  use GenServer
  use AMQP
  alias Phoenix.PubSub.RabbitMQ
  alias Phoenix.PubSub.RabbitMQConsumer, as: Consumer
  require Logger

  @prefetch_count 10

  @moduledoc """
  `Phoenix.PubSub` adapter for RabbitMQ

  See `Phoenix.PubSub.RabbitMQ` for details and configuration options.
  """

  def start_link(server_name, conn_pool_base, pub_pool_base, bk_conn_pool_base, opts) do
    GenServer.start_link(__MODULE__, [server_name, conn_pool_base, pub_pool_base, bk_conn_pool_base, opts], name: server_name)
  end

  @doc """
  Initializes the server.

  """
  def init([server_name, conn_pool_base, pub_pool_base, bk_conn_pool_base, opts]) do
    Process.flag(:trap_exit, true)
    ## TODO: make state compact
    {:ok, %{cons: :ets.new(:rmq_cons, [:set, :private]),
            subs: :ets.new(:rmq_subs, [:set, :private]),
            bk_cons: :ets.new(:rmq_bk_cons, [:set, :private]),
            bk_subs: :ets.new(:rmq_bk_subs, [:set, :private]),
            conn_pool_base: conn_pool_base,
            pub_pool_base: pub_pool_base,
            bk_conn_pool_base: bk_conn_pool_base,
            exchange: rabbitmq_namespace(server_name),
            node_ref: :crypto.strong_rand_bytes(16),
            opts: opts}}
  end

  def subscribe(server_name, pid, topic, opts) do
    GenServer.call(server_name, {:subscribe, pid, topic, opts})
  end
  def unsubscribe(server_name, pid, topic) do
    GenServer.call(server_name, {:unsubscribe, pid, topic})
  end
  def broadcast(server_name,from_pid, topic, msg) do
    GenServer.call(server_name, {:broadcast, from_pid, topic, msg})
  end

  def handle_call({:subscribe, pid, topic, opts}, _from, state) do
    link = Keyword.get(opts, :link, false)

    subs_list = :ets.lookup(state.subs, topic)
    has_key = case subs_list do
                [] -> false
                [{^topic, pids}] -> Enum.find_value(pids, false, fn(x) -> elem(x, 0) == pid end)
              end

    unless has_key do
      pool_index      = RabbitMQ.target_shard_index(topic)
      conn_pool_name = RabbitMQ.create_pool_name(state.conn_pool_base, pool_index)
      {:ok, consumer_pid} = Consumer.start(conn_pool_name,
                                           state.exchange, topic,
                                           pid,
                                           state.node_ref,
                                           link)
      Process.monitor(consumer_pid)

      if link, do: Process.link(pid)

      :ets.insert(state.cons, {consumer_pid, {topic, pid}})
      pids = case subs_list do
        []                -> []
        [{^topic, pids}]  -> pids
      end
      :ets.insert(state.subs, {topic, pids ++ [{pid, consumer_pid}]})

      # register bk server
      bk_pool_index      = RabbitMQ.target_bk_shard_index(topic)
      if state.opts[:bk_shard_num] > 0 && Enum.at(state.opts[:options][:hosts], pool_index-1) != Enum.at(state.opts[:options][:bk_hosts], bk_pool_index-1) do
        bk_conn_pool_name = RabbitMQ.create_pool_name(state.bk_conn_pool_base, bk_pool_index)
        {:ok, bk_consumer_pid} = Consumer.start(bk_conn_pool_name,
                                            state.exchange, topic,
                                            pid,
                                            state.node_ref,
                                            link)
        Process.monitor(bk_consumer_pid)

        :ets.insert(state.bk_cons, {bk_consumer_pid, {topic, pid}})
        bk_subs_list = :ets.lookup(state.bk_subs, topic)
        pids = case bk_subs_list do
          []                -> []
          [{^topic, pids}]  -> pids
        end
        :ets.insert(state.bk_subs, {topic, pids ++ [{pid, bk_consumer_pid}]})
      end

      {:reply, :ok, state}
    end
  end

  def handle_call({:unsubscribe, pid, topic}, _from, state) do
    case :ets.lookup(state.subs, topic) do
      [] ->
        {:reply, :ok, state}
      [{^topic, pids}] ->
        case Enum.find(pids, false, fn(x) -> elem(x, 0) == pid end) do
          nil ->
            {:reply, :ok, state}
          {^pid, consumer_pid} ->
            :ok = Consumer.stop(consumer_pid)
            delete_subscriber(state.subs, pid, topic)

            # delete bk
            case :ets.lookup(state.bk_subs, topic) do
              [] -> nil
              [{^topic, bk_pids}] ->
                case Enum.find(bk_pids, false, fn(x) -> elem(x, 0) == pid end) do
                  nil -> nil
                  {^pid, bk_consumer_pid} ->
                    :ok = Consumer.stop(bk_consumer_pid)
                    delete_subscriber(state.bk_subs, pid, topic)
                end
            end

            {:reply, :ok, state}
        end
    end
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:subscribers, topic}, _from, state) do
    case :ets.lookup(state.subs, topic) do
      []                -> {:reply, [], state}
      [{^topic, pids}]  -> {:reply, Enum.map(pids, fn(x) -> elem(x, 0) end), state}
    end
  end

  def handle_call({:broadcast, from_pid, topic, msg}, _from, state) do
    pool_index    = RabbitMQ.target_shard_index(topic)
    pub_pool_name = RabbitMQ.create_pool_name(state.pub_pool_base, pool_index)
    case RabbitMQ.publish(pub_pool_name,
                          state.exchange,
                          topic,
                          :erlang.term_to_binary({state.node_ref, from_pid, msg}),
                          content_type: "application/x-erlang-binary") do
      :ok              -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid,  _reason}, state) do
    state =
      case :ets.lookup(state.cons, pid) do
        [] -> state
        [{^pid, {topic, sub_pid}}] ->
          :ets.delete(state.cons, pid)
          delete_subscriber(state.subs, sub_pid, topic)

          # delete bk
          case :ets.lookup(state.bk_cons, pid) do
            [] -> nil
            [{^pid, {topic, bk_sub_pid}}] ->
              :ets.delete(state.bk_cons, pid)
              delete_subscriber(state.bk_subs, bk_sub_pid, topic)
          end

          state
      end
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Ignore subscriber exiting; the Consumer will monitor it
    {:noreply, state}
  end

  defp delete_subscriber(subs, pid, topic) do
    case :ets.lookup(subs, topic) do
      []                ->
        subs
      [{^topic, pids}]  ->
        remain_pids = List.keydelete(pids, pid, 0)
        if length(remain_pids) > 0 do
          :ets.insert(subs, {topic, remain_pids})
        else
          :ets.delete(subs, topic)
        end
        subs
    end
  end

  defp rabbitmq_namespace(server_name) do
    case Atom.to_string(server_name) do
      "Elixir." <> name -> name
      name              -> name
    end
  end

end
