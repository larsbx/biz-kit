// eatsbot_extension_kafka: "Ambiguous publish outcomes cannot be recorded as
// acknowledged success".
//
// Rule modelled: Eatsbot.Extensions.Kafka.Driver.produce/3 (driver.ex) returns
// :ok only for {:ok, %RecordMetadata{topic: ^topic, partition: 0, base_offset:
// offset}} with an integer offset >= 0, after KafkaEx.API.produce with acks: 1.
// An error, a mismatched or malformed reply, and an :exit (timeout, lost
// connection) all return {:error, _}, and the driver never resends.
// GUARDED is that strict match; the control accepts any non-error reply.
// Abstracted: successive publishes; the broker reply as a tag; `landed` is whether the
// record reached the leader, which a timeout or error leaves unknown.
module eatsbot_extension_kafka_spec {
  const GUARDED: bool
  pure val REPLIES = Set("ACK", "MISMATCH", "MALFORMED", "ERROR", "EXIT")
  var reply: str          // "" until the broker answers
  var landed: bool
  var recorded: str       // "" | "OK" | "ERROR" for the current publish
  var okWithoutAck: bool  // some publish was recorded OK without an ACK

  action init = all { reply' = "", landed' = false, recorded' = "", okWithoutAck' = false }
  action brokerReply = all { reply == "",
    nondet r = REPLIES.oneOf()
    nondet l = Set(true, false).oneOf()
    all { reply' = r, landed' = if (r == "ACK") true else l, recorded' = recorded,
      okWithoutAck' = okWithoutAck } }
  pure def recordsOk(guarded: bool, r: str): bool =
    r == "ACK" or (not(guarded) and r != "ERROR" and r != "EXIT")
  action driverReturns = all { reply != "", recorded == "",
    recorded' = if (recordsOk(GUARDED, reply)) "OK" else "ERROR",
    okWithoutAck' = (okWithoutAck or (recordsOk(GUARDED, reply) and reply != "ACK")),
    reply' = reply, landed' = landed }
  // The next publish; the driver never resends the previous one.
  action nextPublish = all { recorded != "", reply' = "", landed' = false, recorded' = "",
    okWithoutAck' = okWithoutAck }
  action step = any { brokerReply, driverReturns, nextPublish }

  val obligation = not(okWithoutAck)
  // Ambiguous: the record landed but the caller was told it failed.
  val obligationWitness = not(recorded == "ERROR" and landed)
}
module eatsbot_extension_kafka { import eatsbot_extension_kafka_spec(GUARDED = true).* }
module eatsbot_extension_kafka_control { import eatsbot_extension_kafka_spec(GUARDED = false).* }
