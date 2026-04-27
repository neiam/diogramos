defmodule Diogramos.ULID do
  @moduledoc """
  Generates 26-character Crockford-base32 ULIDs for diagram element ids.

  Format: 48-bit millisecond timestamp ‖ 80 bits of crypto randomness.
  Lexicographic order matches chronological order at millisecond granularity.

      iex> id = Diogramos.ULID.generate()
      iex> String.length(id)
      26
      iex> id =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/
      true
  """

  @alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @spec generate() :: binary()
  def generate do
    ts = System.system_time(:millisecond)
    rand = :crypto.strong_rand_bytes(10)
    encode(<<ts::big-unsigned-48, rand::binary>>)
  end

  @spec timestamp(binary()) :: {:ok, integer()} | :error
  def timestamp(<<_::binary-size(26)>> = ulid) do
    with {:ok, <<ts::big-unsigned-48, _rest::binary>>} <- decode(ulid) do
      {:ok, ts}
    end
  end

  def timestamp(_), do: :error

  defp encode(<<int::big-unsigned-128>>), do: do_encode(int, 26, [])

  defp do_encode(_int, 0, acc), do: IO.iodata_to_binary(acc)

  defp do_encode(int, n, acc) do
    ch = :binary.at(@alphabet, rem(int, 32))
    do_encode(div(int, 32), n - 1, [ch | acc])
  end

  defp decode(<<chars::binary-size(26)>>) do
    chars
    |> :binary.bin_to_list()
    |> Enum.reduce_while({:ok, 0}, fn c, {:ok, acc} ->
      case decode_char(c) do
        :error -> {:halt, :error}
        n -> {:cont, {:ok, acc * 32 + n}}
      end
    end)
    |> case do
      {:ok, int} when int < 0x100000000000000000000000000000000 ->
        {:ok, <<int::big-unsigned-128>>}

      _ ->
        :error
    end
  end

  for {ch, idx} <- Enum.with_index(~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ") do
    defp decode_char(unquote(ch)), do: unquote(idx)
  end

  for {ch, idx} <- Enum.with_index(~c"abcdefghjkmnpqrstvwxyz", 10) do
    defp decode_char(unquote(ch)), do: unquote(idx)
  end

  defp decode_char(_), do: :error
end
