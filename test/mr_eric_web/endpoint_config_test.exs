defmodule MrEricWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  test "endpoint has a non-nil secret_key_base of at least 32 bytes after boot" do
    config = Application.fetch_env!(:mr_eric, MrEricWeb.Endpoint)
    secret_key_base = Keyword.fetch!(config, :secret_key_base)

    assert is_binary(secret_key_base)
    assert byte_size(secret_key_base) >= 32
  end
end
