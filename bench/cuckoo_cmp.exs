Mix.Task.run("app.start")

alias Fate.Filter.Cuckoo
alias Fate.Hash

inputs =
  %{
    "1k integers" => Enum.to_list(1..1_000),
    "10k integers" => Enum.to_list(1..10_000),
    "100k integers" => Enum.to_list(1..100_000),
    "1M integers" => Enum.to_list(1..1_000_000)
  }

# Use Default (phash2) for fair comparison with Erlang cuckoo_filter
hash_module = Fate.Hash.Default

Benchee.run(
  %{
    "Fate.Cuckoo put/2" => fn data ->
      filter =
        Cuckoo.new(length(data),
          hash_module: hash_module
        )

      Enum.each(data, &Cuckoo.put(filter, &1))
      filter
    end,
    ":cuckoo_filter.add/2" => fn data ->
      filter = :cuckoo_filter.new(length(data))
      Enum.each(data, &:cuckoo_filter.add(filter, &1))
      filter
    end
  },
  inputs: inputs,
  time: 5
)

Benchee.run(
  %{
    "Fate.Cuckoo member?/2" => fn %{fate_filter: filter, data: data} ->
      Enum.each(data, &Cuckoo.member?(filter, &1))
    end,
    ":cuckoo_filter.contains/2" => fn %{cuckoo_filter: filter, data: data} ->
      Enum.each(data, &:cuckoo_filter.contains(filter, &1))
    end
  },
  inputs: inputs,
  before_scenario: fn data ->
    fate_filter =
      Cuckoo.new(length(data),
        hash_module: hash_module
      )

    Enum.each(data, &Cuckoo.put(fate_filter, &1))

    cuckoo_filter = :cuckoo_filter.new(length(data))
    Enum.each(data, &:cuckoo_filter.add(cuckoo_filter, &1))

    %{data: data, fate_filter: fate_filter, cuckoo_filter: cuckoo_filter}
  end,
  time: 5
)
