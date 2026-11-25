## Strict reply-schema validation and RUNE-safe display sanitization.

import
  std/[json, strutils, unicode, unittest],
  ../src/pistonball/[sim, scripts]

const ValidJson = """{"mode":"wave","trigger_m":0.8,"lead_ticks":6,"up_m":1.45,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle","note":"lift behind","say":"up"}"""

proc parsed(text: string): PistonScript =
  parsePistonScript(extractJsonObject(text))

suite "the reply schema":
  test "a valid single JSON object and fenced JSON object are accepted":
    let a = parsed(ValidJson)
    check a.mode == modeWave
    check a.triggerUm == 800_000'i32
    check a.leadTicks == 6
    check a.upUm == 1_450_000'i32
    check a.downUm == 100_000'i32
    check a.idleUm == 250_000'i32
    check a.speed255 == 255
    check a.blind == blindIdle
    check validScript(a)

    let b = parsed("```json\n" & ValidJson & "\n```")
    check b.mode == modeWave
    check b.upUm == 1_450_000'i32

  test "prose around JSON is rejected":
    expect ScriptError:
      discard parsed("Sure! Here is my program:\n" & ValidJson & "\nHope that helps.")

  test "legacy percentages, centimetres, and numeric strings are rejected":
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":50,"lead_ticks":6,"up_m":1.45,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":6,"up_m":145,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":6,"up_m":1.45,"down_m":0.1,"idle_m":0.25,"speed":80,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":"7","up_m":"1.30","down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")

  test "unknown mode and unknown blind are rejected":
    expect ScriptError:
      discard parsed("""{"mode":"zigzag","trigger_m":0.8,"lead_ticks":6,"up_m":1.0,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":6,"up_m":1.0,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"teleport"}""")

  test "absent and out-of-range control fields are rejected rather than repaired":
    expect ScriptError:
      discard parsed("""{"mode":"wave"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":25,"up_m":1.0,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":6,"up_m":1.7,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":6,"up_m":1.0,"down_m":-0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":1.2,"lead_ticks":6,"up_m":1.0,"down_m":0.1,"idle_m":0.25,"speed":1.0,"blind":"idle"}""")
    expect ScriptError:
      discard parsed("""{"mode":"wave","trigger_m":0.8,"lead_ticks":6,"up_m":1.0,"down_m":0.1,"idle_m":0.25,"speed":-0.1,"blind":"idle"}""")

  test "a 300-character spectator note is cut to 160 RUNES without rejecting valid controls":
    var long = ""
    for _ in 0 ..< 300:
      long.add("x")
    let node = parseJson(ValidJson)
    node["note"] = %long
    let a = parsePistonScript(node)
    check a.note.runeLen == MaxNoteRunes
    check a.mode == modeWave

  test "a say whose 48th and 49th characters are a 4-byte emoji cuts on the RUNE boundary":
    var say = ""
    for _ in 0 ..< 47:
      say.add("a")
    say.add("\xF0\x9F\x9B\xA0")          # U+1F6E0, four bytes
    say.add("\xF0\x9F\x9B\xA0")
    let node = parseJson(ValidJson)
    node["say"] = %say
    let a = parsePistonScript(node)
    check a.say.runeLen <= MaxSayRunes
    check a.say.validateUtf8() == -1     # still valid UTF-8: no half codepoint
    let record = boundedScriptRecord(a, 3, 4, 9, alias(9))
    check record.runeLen <= MaxScriptRecordRunes
    let parsedRecord = parseJson(record)
    check parsedRecord["say"].getStr().runeLen <= MaxSayRunes
    check parsedRecord["k"].getStr() == "script"

  test "a reply with no usable object is rejected":
    expect ScriptError:
      discard parsed("{\"note\":\"thinking about it\"}")
    expect ScriptError:
      discard parsed("I would rather not answer.")

  test "the record never exceeds its rune cap even with a full note and say":
    var script = defaultScript()
    script.note = repeat("n", MaxNoteRunes)
    script.say = repeat("s", MaxSayRunes)
    let record = boundedScriptRecord(script, 7, 19, 19, alias(19))
    check record.runeLen <= MaxScriptRecordRunes
    discard parseJson(record)

  test "metresText and unitText render from integers only":
    check metresText(1_450_000'i32) == "1.45"
    check metresText(0'i32) == "0.00"
    check metresText(60_000'i32) == "0.06"
    check unitText(255) == "1.00"
    check unitText(0) == "0.00"
    check unitText(204) == "0.80"
