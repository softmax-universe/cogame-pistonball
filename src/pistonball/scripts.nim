## The piston-program schema: what a policy (LLM or scripted) may say, strict
## parsing/validation of model replies, and RUNE-safe display sanitization.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — that is what makes the bounded-orders test
## in `tests/test_baselines.nim` meaningful.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in
## a browser and then fails a strict UTF-8 parser, which is exactly the class
## of bug that makes a replay unreadable to everything except the one viewer
## that happened to be lenient.
##
## The script is stored in INTEGERS (micrometres, ticks, 0..255) so a record
## round-trips exactly; the controller that consumes it sits outside the
## determinism boundary and may do as it likes.

import
  std/[json, math, strutils, unicode],
  ./sim_types

type
  Mode* = enum
    ## A closed enum. An unrecognised mode repairs to last turn's mode, else
    ## `wave`, so a piston is never left uncommanded.
    modeWave = "wave"
    modeLift = "lift"
    modeDrop = "drop"
    modeHold = "hold"
    modeCatch = "catch"
    modeRipple = "ripple"

  Blind* = enum
    ## What a piston does while it cannot see the ball.
    blindHold = "hold"
    blindIdle = "idle"
    blindRipple = "ripple"

  ScriptSource* = enum
    srcLlm = "llm"
    srcScripted = "scripted"
    srcFallback = "fallback"

  PistonScript* = object
    note*: string          ## <= MaxNoteRunes, the policy's own line.
    mode*: Mode
    triggerUm*: int32      ## 0 .. WindowHalfWidth.
    leadTicks*: int        ## 0 .. 24.
    upUm*, downUm*, idleUm*: int32   ## 0 .. Stroke.
    speed255*: int         ## 0 .. 255, a fraction of MaxPistonSpeed.
    blind*: Blind
    say*: string           ## <= MaxSayRunes, spectators only.
    source*: ScriptSource
    latencyMs*: int

  ScriptError* = object of ValueError

const
  DefaultTriggerUm* = WindowHalfWidth
  DefaultLeadTicks* = 6
  DefaultUpUm* = 1_450_000'i32
  DefaultDownUm* = 100_000'i32
  DefaultIdleUm* = 250_000'i32
  DefaultSpeed255* = 255

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeNote*(text: string): string =
  ## The policy's own line as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  ##
  ## `strutils.strip` is QUALIFIED, and it runs BEFORE the rune cut. `unicode`
  ## is imported here for `runeLen`/`runeSubStr`, and its own `strip` treats
  ## U+00A0 as a space — which on a byte-level trailing sequence chews the last
  ## byte off a multi-byte codepoint and leaves exactly the half-character this
  ## whole file exists to prevent.
  strutils.strip(text.replace("\n", " ").replace("\r", " "))
    .truncateRunes(MaxNoteRunes)

proc sanitizeSay*(text: string): string =
  ## A piston's spectator line: capped at MaxSayRunes on a RUNE boundary
  ## first, then stripped of control characters. Doing it in that order means
  ## the rune cut never leaves half a codepoint behind. Braces are excluded
  ## deliberately: the replay chat stream tells a control record from a plain
  ## line by a leading '{'.
  ##
  ## The strip is QUALIFIED and runs FIRST, before the rune cut: see
  ## `sanitizeNote`.
  result = ""
  for rune in strutils.strip(text).truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value < 32 or value == ord('{') or value == ord('}'):
      continue
    result.add($rune)

proc defaultScript*(): PistonScript =
  PistonScript(
    note: "",
    mode: modeWave,
    triggerUm: DefaultTriggerUm,
    leadTicks: DefaultLeadTicks,
    upUm: DefaultUpUm,
    downUm: DefaultDownUm,
    idleUm: DefaultIdleUm,
    speed255: DefaultSpeed255,
    blind: blindHold,
    say: "",
    source: srcScripted,
    latencyMs: 0
  )

proc parseMode*(text: string): Mode =
  ## Strict enum match for `mode`.
  for value in Mode:
    if $value == text:
      return value
  raise newException(ScriptError, "invalid mode: " & text)

proc parseBlind*(text: string): Blind =
  ## Strict enum match for `blind`.
  for value in Blind:
    if $value == text:
      return value
  raise newException(ScriptError, "invalid blind: " & text)

proc extractJsonObject*(text: string): JsonNode =
  ## Extracts a single JSON object from a model reply, tolerating a markdown
  ## fence around the JSON object while rejecting missing or malformed JSON.
  var trimmed = strutils.strip(text)
  if trimmed.startsWith("```"):
    let firstNl = trimmed.find('\n')
    if firstNl >= 0:
      trimmed = trimmed[firstNl + 1 .. ^1]
      if trimmed.endsWith("```"):
        trimmed = trimmed[0 ..< trimmed.len - 3]
      trimmed = strutils.strip(trimmed)
  if trimmed.len == 0 or trimmed[0] != '{' or trimmed[^1] != '}':
    var head = strutils.strip(text)
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      ScriptError, "reply is not a single JSON object: " & head.replace("\n", " "))
  try:
    result = parseJson(trimmed)
  except CatchableError as error:
    raise newException(ScriptError, "malformed JSON object: " & error.msg)
  if result.kind != JObject:
    raise newException(ScriptError, "reply is not a JSON object")

proc requireFiniteNumber(payload: JsonNode, key: string): float =
  if not payload.hasKey(key):
    raise newException(ScriptError, "missing required field: " & key)
  let node = payload[key]
  case node.kind
  of JInt:
    result = float(node.getBiggestInt())
  of JFloat:
    result = node.getFloat()
    if classify(result) in {fcNan, fcInf, fcNegInf}:
      raise newException(ScriptError, "non-finite number for field: " & key)
  else:
    raise newException(ScriptError, "field must be a number: " & key)

proc requireMetres(payload: JsonNode, key: string, maxUm: int32): int32 =
  let metres = requireFiniteNumber(payload, key)
  let maxMetres = float(maxUm) / 1_000_000.0
  if metres < 0.0 or metres > maxMetres:
    raise newException(ScriptError, "field out of range [0, " & $maxMetres & "]: " & key)
  int32(round(metres * 1_000_000.0))

proc requireUnit(payload: JsonNode, key: string): int =
  let unit = requireFiniteNumber(payload, key)
  if unit < 0.0 or unit > 1.0:
    raise newException(ScriptError, "field out of range [0, 1]: " & key)
  int(round(unit * 255.0))

proc requireTicks(payload: JsonNode, key: string): int =
  if not payload.hasKey(key):
    raise newException(ScriptError, "missing required field: " & key)
  let node = payload[key]
  if node.kind != JInt:
    raise newException(ScriptError, "field must be an integer: " & key)
  let ticks = node.getBiggestInt()
  if ticks < 0 or ticks > 24:
    raise newException(ScriptError, "field out of range [0, 24]: " & key)
  int(ticks)

proc optionalString(payload: JsonNode, key: string): string =
  if not payload.hasKey(key) or payload[key].kind == JNull:
    return ""
  if payload[key].kind != JString:
    raise newException(ScriptError, "field must be a string: " & key)
  payload[key].getStr()

proc parsePistonScript*(payload: JsonNode): PistonScript =
  ## Strictly parses and validates one piston-program JSON object.
  ## Raises `ScriptError` on any missing, wrong-type, or out-of-range control
  ## field; never repairs, clamps, converts units, or invents defaults.
  if payload.isNil or payload.kind != JObject:
    raise newException(ScriptError, "reply is not a JSON object")
  if not payload.hasKey("mode") or payload["mode"].kind != JString:
    raise newException(ScriptError, "missing or non-string required field: mode")
  if not payload.hasKey("blind") or payload["blind"].kind != JString:
    raise newException(ScriptError, "missing or non-string required field: blind")
  result = defaultScript()
  result.mode = parseMode(payload["mode"].getStr())
  result.blind = parseBlind(payload["blind"].getStr())
  result.triggerUm = requireMetres(payload, "trigger_m", WindowHalfWidth)
  result.leadTicks = requireTicks(payload, "lead_ticks")
  result.upUm = requireMetres(payload, "up_m", Stroke)
  result.downUm = requireMetres(payload, "down_m", Stroke)
  result.idleUm = requireMetres(payload, "idle_m", Stroke)
  result.speed255 = requireUnit(payload, "speed")
  result.note = sanitizeNote(optionalString(payload, "note"))
  result.say = sanitizeSay(optionalString(payload, "say"))
  result.source = srcLlm

proc metresText*(micro: int32): string =
  ## A micrometre quantity as a 2-decimal metre string, built from integers so
  ## a record never carries a platform-dependent float rendering.
  let
    negative = micro < 0
    value = (if negative: -int64(micro) else: int64(micro))
    whole = value div 1_000_000
    hundredths = (value mod 1_000_000) div 10_000
  var text = $whole & "." & (if hundredths < 10: "0" else: "") & $hundredths
  if negative:
    text = "-" & text
  text

proc unitText*(speed255: int): string =
  ## A 0..255 speed as a 2-decimal 0..1 string.
  let hundredths = (speed255 * 100 + 127) div 255
  if hundredths >= 100: "1.00"
  else: "0." & (if hundredths < 10: "0" else: "") & $hundredths

proc scriptJson*(script: PistonScript): JsonNode =
  ## The script fields, exactly as the reply schema names them.
  %*{
    "mode": $script.mode,
    "trigger_m": parseFloat(metresText(script.triggerUm)),
    "lead_ticks": script.leadTicks,
    "up_m": parseFloat(metresText(script.upUm)),
    "down_m": parseFloat(metresText(script.downUm)),
    "idle_m": parseFloat(metresText(script.idleUm)),
    "speed": parseFloat(unitText(script.speed255)),
    "blind": $script.blind
  }

proc appliedScriptAction*(script: PistonScript): JsonNode =
  ## Canonical installed controls and the actual bounded lines emitted by the engine.
  result = scriptJson(script)
  result["note"] = %script.note
  result["say"] = %script.say

proc scriptRecord*(
  script: PistonScript, turn, seat, piston: int, alias: string
): JsonNode =
  ## The replay chat record for one turn's script. Re-applied at playback into
  ## NON-HASHED sim fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  result = %*{
    "k": "script",
    "turn": turn,
    "seat": seat,
    "alias": alias,
    "piston": piston,
    "source": $script.source,
    "latency_ms": script.latencyMs,
    "note": script.note,
    "say": script.say
  }
  let fields = scriptJson(script)
  for key, value in fields.pairs:
    result[key] = value

proc boundedScriptRecord*(
  script: PistonScript, turn, seat, piston: int, alias: string
): string =
  ## The serialized script record, guaranteed <= MaxScriptRecordRunes. The
  ## note is the only unbounded-in-practice field, so it is the one that
  ## shrinks; the cut still lands on a rune boundary. NEVER cut the serialized
  ## string — that would emit broken JSON, which is the exact failure the rune
  ## rule exists to prevent.
  var trimmed = script
  result = $trimmed.scriptRecord(turn, seat, piston, alias)
  var guard = 0
  while result.runeLen > MaxScriptRecordRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $trimmed.scriptRecord(turn, seat, piston, alias)

proc validScript*(script: PistonScript): bool =
  ## The reply-schema legality predicate, shared by the tolerant parser's
  ## tests and the scripted baselines' bounded-orders assertion.
  script.triggerUm >= 0 and script.triggerUm <= WindowHalfWidth and
    script.leadTicks >= 0 and script.leadTicks <= 24 and
    script.upUm >= 0 and script.upUm <= Stroke and
    script.downUm >= 0 and script.downUm <= Stroke and
    script.idleUm >= 0 and script.idleUm <= Stroke and
    script.speed255 >= 0 and script.speed255 <= 255 and
    script.note.runeLen <= MaxNoteRunes and
    script.say.runeLen <= MaxSayRunes
