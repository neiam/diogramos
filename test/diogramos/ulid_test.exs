defmodule Diogramos.ULIDTest do
  use ExUnit.Case, async: true
  doctest Diogramos.ULID

  alias Diogramos.ULID

  test "ids generated across milliseconds sort chronologically" do
    a = ULID.generate()
    Process.sleep(2)
    b = ULID.generate()
    assert a < b
  end

  test "10k generated ids are unique" do
    ids = for _ <- 1..10_000, do: ULID.generate()
    assert length(Enum.uniq(ids)) == 10_000
  end

  test "timestamp/1 round-trips with the embedded millisecond clock" do
    before = System.system_time(:millisecond)
    {:ok, ts} = ULID.timestamp(ULID.generate())
    later = System.system_time(:millisecond)
    assert before <= ts and ts <= later
  end

  test "timestamp/1 rejects malformed input" do
    assert ULID.timestamp("too-short") == :error
    assert ULID.timestamp("00000000000000000000000000!") == :error
  end
end
