defmodule Dispatch.Fleet.ReferenceCipher do
  @moduledoc "Encrypted opaque proof locators. No fetching, uploading or execution."
  @aad "dispatch-document-reference-v1"
  def encrypt(reference) do
    with {:ok, key} <- key() do
      iv = :crypto.strong_rand_bytes(12)
      {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, reference, @aad, true)
      {:ok, <<iv::binary, tag::binary, cipher::binary>>}
    end
  end

  def decrypt(<<iv::binary-size(12), tag::binary-size(16), cipher::binary>>) do
    with {:ok, key} <- key(),
         text when is_binary(text) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, @aad, tag, false) do
      {:ok, text}
    else
      _ -> {:error, :unavailable}
    end
  end

  def decrypt(_), do: {:error, :unavailable}

  defp key do
    case Application.get_env(:dispatch, :document_reference_key) do
      key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :unavailable}
    end
  end
end
