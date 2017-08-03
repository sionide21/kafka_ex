defmodule KafkaEx.ConsumerGroup do
  @moduledoc """
  A process that manages membership in a Kafka consumer group.

  Consumers in a consumer group coordinate with each other through a Kafka
  broker to distribute the work of consuming one or several topics without any
  overlap. This is facilitated by the
  [Kafka client-side assignment protocol](https://cwiki.apache.org/confluence/display/KAFKA/Kafka+Client-side+Assignment+Proposal).

  Any time group membership changes (a member joins or leaves the group), a
  Kafka broker initiates group synchronization by asking one of the group
  members (the leader elected by the broker) to provide partition assignments
  for the whole group.  KafkaEx uses a round robin partition assignment
  algorithm by deafult.  This can be overridden by passing a callback function
  in the `:partition_assignment_callback` option.  See
  `KafkaEx.ConsumerGroup.PartitionAssignment` for details on partition
  assignment functions.

  A `KafkaEx.ConsumerGroup` process is responsible for:

  1. Maintaining membership in a Kafka consumer group.
  2. Determining partition assignments if elected as the group leader.
  3. Launching and terminating `KafkaEx.GenConsumer` processes based on its
    assigned partitions.

  To use a `KafkaEx.ConsumerGroup`, a developer must define a module that
  implements the `KafkaEx.GenConsumer` behaviour and start a
  `KafkaEx.ConsumerGroup` configured to use that module.

  ## Example

  Suppose we want to consume from a topic called `"example_topic"` with a
  consumer group named `"example_group"` and we have a `KafkaEx.GenConsumer`
  implementation called `ExampleGenConsumer` (see the `KafkaEx.GenConsumer`
  documentation).  We could start a consumer group in our application's
  supervision tree as follows:

  ```
  defmodule MyApp do
    use Application

    def start(_type, _args) do
      import Supervisor.Spec

      consumer_group_opts = [
        # setting for the ConsumerGroup
        heartbeat_interval: 1_000,
        # this setting will be forwarded to the GenConsumer
        commit_interval: 1_000
      ]

      gen_consumer_impl = ExampleGenConsumer
      consumer_group_name = "example_group"
      topic_names = ["example_topic"]

      children = [
        # ... other children
        supervisor(
          KafkaEx.ConsumerGroup,
          [gen_consumer_impl, consumer_group_name, topic_names, consumer_group_opts]
        )
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end
  end
  ```

  **Note** It is not necessary for the Elixir nodes in a consumer group to be
  connected (i.e., using distributed Erlang methods).  The coordination of
  group consumers is mediated by the broker.

  See `start_link/4` for configuration details.
  """

  use Supervisor

  alias KafkaEx.ConsumerGroup.PartitionAssignment

  @typedoc """
  Option values used when starting a consumer group

  * `:heartbeat_interval` - How frequently, in milliseconds, to send heartbeats
     to the broker.  This impacts how quickly we will process partition
     changes as consumers start/stop.  Default: 5000 (5 seconds).
  * `:session_timeout` - Consumer group session timeout in milliseconds.
     Default: 30000 (30 seconds).  See below.
  * Any of `t:KafkaEx.GenConsumer.option/0`,
     which will be passed on to consumers
  * `:gen_server_opts` - `t:GenServer.options/0` passed on to the manager
     GenServer
  * `:name` - Name for the consumer group supervisor
  * `:max_restarts`, `:max_seconds` - Supervisor restart policy parameters
  * `:partition_assignment_callback` - See
     `t:KafkaEx.ConsumerGroup.PartitionAssignment.callback/0`

  Note `:session_timeout` is registered with the broker and determines how long
  before the broker will de-register a consumer from which it has not heard a
  heartbeat.  This value must between the broker cluster's configured values
  for `group.min.session.timeout.ms` and `group.max.session.timeout.ms` (6000
  and 30000 by default).  See
  [https://kafka.apache.org/documentation/#configuration](https://kafka.apache.org/documentation/#configuration).
  """
  @type option :: KafkaEx.GenConsumer.option
    | {:heartbeat_interval, pos_integer}
    | {:session_timeout, pos_integer}
    | {:partition_assignment_callback, PartitionAssignment.callback}
    | {:gen_server_opts, GenServer.options}
    | {:name, Supervisor.name}
    | {:max_restarts, non_neg_integer}
    | {:max_seconds, non_neg_integer}

  @type options :: [option]

  @doc """
  Starts a consumer group process tree process linked to the current process.

  This can be used to start a `KafkaEx.ConsumerGroup` as part of a supervision
  tree.

  `module` is a module that implements the `KafkaEx.GenConsumer` behaviour.
  `group_name` is the name of the consumer group. `topics` is a list of topics
  that the consumer group should consume from.  `opts` can be composed of
  options for the supervisor as well as for the `KafkEx.GenConsumer` processes
  that will be spawned by the supervisor.  See `t:option/0` for details.

  ### Return Values

  This function has the same return values as `Supervisor.start_link/3`.
  """
  @spec start_link(module, binary, [binary], options) :: Supervisor.on_start
  def start_link(consumer_module, group_name, topics, opts \\ []) do
    {supervisor_opts, module_opts} =
      Keyword.split(opts, [:name, :strategy, :max_restarts, :max_seconds])

    Supervisor.start_link(
      __MODULE__,
      {consumer_module, group_name, topics, module_opts},
      supervisor_opts
    )
  end

  @doc false # used by ConsumerGroup to set partition assignments
  def start_consumer(pid, consumer_module, group_name, assignments, opts) do
    child = supervisor(
      KafkaEx.GenConsumer.Supervisor,
      [consumer_module, group_name, assignments, opts],
      id: :consumer
    )

    case Supervisor.start_child(pid, child) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
    end
  end

  @doc false # used by ConsumerGroup to pause consumption during rebalance
  def stop_consumer(pid) do
    case Supervisor.terminate_child(pid, :consumer) do
      :ok ->
        Supervisor.delete_child(pid, :consumer)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc false
  def init({consumer_module, group_name, topics, opts}) do
    opts = Keyword.put(opts, :supervisor_pid, self())

    children = [
      worker(
        KafkaEx.ConsumerGroup.Manager,
        [consumer_module, group_name, topics, opts]
      ),
    ]

    supervise(children, strategy: :one_for_all)
  end
end
