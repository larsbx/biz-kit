defmodule DispatchWeb.DatastarTest do
  @moduledoc """
  Golden wire-format tests required by Sections 21.5 and 33.2.

  These assert bytes, not behaviour. Datastar parses the stream by exact prefix
  and blank-line framing, so a stray space or a missing terminator breaks every
  open portal stream in a way no higher-level test would catch.
  """

  use ExUnit.Case, async: true

  doctest DispatchWeb.Datastar

  alias DispatchWeb.Datastar

  test "a single-line fragment encodes as one data: elements line" do
    assert Datastar.patch_elements(~s(<section id="participant-status-card">x</section>)) ==
             "event: datastar-patch-elements\n" <>
               ~s(data: elements <section id="participant-status-card">x</section>\n) <>
               "\n"
  end

  test "multiline HTML repeats the data: elements prefix on every line" do
    html = """
    <section id="participant-timeline">
      <p>entry</p>
    </section>\
    """

    assert Datastar.patch_elements(html, id: "018f-example-event") ==
             "id: 018f-example-event\n" <>
               "event: datastar-patch-elements\n" <>
               ~s(data: elements <section id="participant-timeline">\n) <>
               "data: elements   <p>entry</p>\n" <>
               "data: elements </section>\n" <>
               "\n"
  end

  test "every event terminates with a blank line" do
    for encoded <- [
          Datastar.patch_elements("<p id=\"a\">a</p>"),
          Datastar.patch_many(["<p id=\"a\">a</p>", "<p id=\"b\">b</p>"]),
          Datastar.heartbeat(),
          Datastar.retry(1_000)
        ] do
      assert String.ends_with?(encoded, "\n\n")
    end
  end

  test "patch_many joins fragments into one event" do
    encoded = Datastar.patch_many([~s(<p id="a">a</p>), ~s(<p id="b">b</p>)], id: "e2")

    assert encoded ==
             "id: e2\n" <>
               "event: datastar-patch-elements\n" <>
               ~s(data: elements <p id="a">a</p>\n) <>
               ~s(data: elements <p id="b">b</p>\n) <>
               "\n"
  end

  test "an event id is omitted when not supplied" do
    refute Datastar.patch_elements("<p id=\"a\">a</p>") =~ "id:"
  end

  test "the heartbeat is a comment frame that patches nothing" do
    assert Datastar.heartbeat() == ": heartbeat\n\n"
  end

  test "the heartbeat interval matches the 20 seconds required by Section 24.5" do
    assert Datastar.heartbeat_interval_ms() == 20_000
  end
end
