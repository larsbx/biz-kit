// eatsbot_extension_telegram_bot: "Unverified Telegram messages cannot
// authorize business effects".
//
// Rule modelled: Eatsbot.Extensions.TelegramBot.Controller runs plug
// :verify_secret_token before update/2. A request passes only when the
// configured webhook_secret is a binary matching ~r/\A[A-Za-z0-9_-]{1,256}\z/
// and the single x-telegram-bot-api-secret-token header equals it
// (Plug.Crypto.secure_compare); otherwise 401 and halt. Only update/2 reaches
// Handler.on_update and the chains (e.g. /done, /new) that change deliveries.
// GUARDED is that plug. Abstracted: the sender as Telegram (knows the secret)
// or an impostor; the configured secret as valid, malformed or unset.
module eatsbot_extension_telegram_bot_spec {
  const GUARDED: bool
  var config: str               // "VALID" | "MALFORMED" | "UNSET"
  var effects: int              // business effects caused by webhook requests
  var unverifiedEffect: bool    // an effect came from a request that did not verify

  pure def verifies(config: str, header: str): bool = config == "VALID" and header == "SECRET"

  action init = all { nondet c = Set("VALID", "MALFORMED", "UNSET").oneOf() config' = c,
    effects' = 0, unverifiedEffect' = false }
  action request = all {
    nondet header = Set("SECRET", "WRONG", "MISSING").oneOf()
    val passes = not(GUARDED) or verifies(config, header)
    all { effects' = if (passes) effects + 1 else effects,
      unverifiedEffect' = (unverifiedEffect or (passes and not(verifies(config, header)))),
      config' = config } }
  action step = request

  val obligation = not(unverifiedEffect)
  val obligationWitness = effects == 0
}
module eatsbot_extension_telegram_bot { import eatsbot_extension_telegram_bot_spec(GUARDED = true).* }
module eatsbot_extension_telegram_bot_control { import eatsbot_extension_telegram_bot_spec(GUARDED = false).* }
