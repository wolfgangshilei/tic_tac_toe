defmodule TicTacToeRouterTest do
  use ExUnit.Case

  alias TicTacToe.Router, as: R
  alias TicTacToeRouterTest.TestGameServer

  test "start the router with unknown worker module." do
    Process.flag(:trap_exit, true)
    R.start_link([worker_server_mod: TestGameServerUnknown])
    receive do
      {:"EXIT", _, {:worker_server_mod_not_exist, _}}->
        assert true
      after
        3000 -> assert false
    end
  end

  test "trying to apply undefined function at runtime" do
    {:ok, _} = start_supervised({TicTacToe.Supervisor, [game_server_mod: TestGameServer]})
    {:ok, worker} = R.new_worker

    assert {:error, {:undefined_function, {TestGameServer, :some_fn, 1}}} ==
      R.route_to(worker, :some_fn)

    :ok = stop_supervised(TicTacToe.Supervisor)
  end

  test "start a new worker via the router." do
    {:ok, _} = start_supervised({TicTacToe.Supervisor, [game_server_mod: TestGameServer]})
    {:ok, game_id} = R.new_worker()
    assert is_reference(game_id)
    :ok = stop_supervised(TicTacToe.Supervisor)
  end

  test "operate via the router." do
    {:ok, _} = start_supervised({TicTacToe.Supervisor, [game_server_mod: TestGameServer]})
    {:ok, game_id} = R.new_worker()

    R.route_to(game_id, {:do_op, [:operation1]})
    R.route_to(game_id, {:do_op, [:operation2]})
    {:ok, %{history: history}} = R.route_to(game_id, {:do_op, [:operation3]})

    assert history == [:operation2, :operation1]

    :ok = stop_supervised(TicTacToe.Supervisor)
  end

  test "normally stopped workers with reason :normal, :shutdown or {:shutdown, _} don't get restarted." do
    {:ok, _} = start_supervised({TicTacToe.Supervisor, [game_server_mod: TestGameServer]})
    {:ok, game_id} = R.new_worker()

    assert %{active: 1, workers: 1, specs: 1, supervisors: 0} ==
      Supervisor.count_children(TicTacToe.GameServerSup)
    R.route_to(game_id, {:do_op, [:stop]})
    assert %{active: 0, workers: 0, specs: 0, supervisors: 0} ==
      Supervisor.count_children(TicTacToe.GameServerSup)

    {:ok, game_id} = R.new_worker()
    assert %{active: 1, workers: 1, specs: 1, supervisors: 0} ==
      Supervisor.count_children(TicTacToe.GameServerSup)
    {:ok, %{pid: pid}} = R.route_to(game_id, {:do_op, [:op]})
    :erlang.exit(pid, {:shutdown, :ok})
    :timer.sleep(1000)
    assert %{active: 0, workers: 0, specs: 0, supervisors: 0} ==
      Supervisor.count_children(TicTacToe.GameServerSup)

    :ok = stop_supervised(TicTacToe.Supervisor)
  end

  test "abnormally exit work will be automatically restarted" do
    {:ok, _} = start_supervised({TicTacToe.Supervisor, [game_server_mod: TestGameServer]})
    {:ok, game_id} = R.new_worker()

    assert %{active: 1, workers: 1, specs: 1, supervisors: 0} ==
      Supervisor.count_children(TicTacToe.GameServerSup)

    {:ok, %{pid: pid}} = R.route_to(game_id, {:do_op, [:op]})
    :erlang.exit(pid, :crashed)
    :timer.sleep(1000)
    assert %{active: 1, workers: 1, specs: 1, supervisors: 0} ==
      Supervisor.count_children(TicTacToe.GameServerSup)

    {:ok, %{pid: new_pid}} = R.route_to(game_id, {:do_op, [:op]})

    refute pid == new_pid

    :ok = stop_supervised(TicTacToe.Supervisor)
  end

  test "concurrent workers" do
    {:ok, _} = start_supervised({TicTacToe.Supervisor, [game_server_mod: TestGameServer]})
    {:ok, game_id_1} = R.new_worker()
    {:ok, game_id_2} = R.new_worker()

    R.route_to(game_id_1, {:do_op, [:g1_op_1]})
    R.route_to(game_id_1, {:do_op, [:g1_op_2]})

    R.route_to(game_id_2, {:do_op, [:g2_op_1]})
    R.route_to(game_id_2, {:do_op, [:g2_op_2]})

    {:ok, %{pid: pid_1, history: h1}} = R.route_to(game_id_1, {:do_op, [:get]})
    {:ok, %{pid: pid_2, history: h2}} = R.route_to(game_id_2, {:do_op, [:get]})

    refute pid_1 == pid_2
    assert h1 == [:g1_op_2, :g1_op_1]
    assert h2 == [:g2_op_2, :g2_op_1]

    :ok = stop_supervised(TicTacToe.Supervisor)
  end
end

defmodule TicTacToeRouterTest.TestGameServer do
  use GenServer

  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args)
  end

  def do_op(game_server, :stop) do
    GenServer.stop(game_server)
  end
  def do_op(game_server, op) do
    GenServer.call(game_server, op)
  end

  def init(_init_args) do
    {:ok, %{pid: self(),
            history: []}}
  end

  def handle_call(operation, _from, state) do
    {:reply, state, Map.update!(state, :history, &([operation | &1]))}
  end
end
