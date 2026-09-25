// ric.ninfer — helpers for the NInfer Qwen bar widget / panel.
//
// Parses the `ninfer-qwen info` key=value feed and formats values for
// display. All functions are pure so they can be unit-tested outside Qt.

var VALID_STATES = ["off", "starting", "ready", "failed"]

// Parse "key=value\n..." into a plain object. The state is always
// normalized to a valid value (empty/failed feeds read as "off").
function parseInfo(raw) {
  var out = { state: "off" }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    out[line.slice(0, eq)] = line.slice(eq + 1)
  }
  if (VALID_STATES.indexOf(out.state) < 0) out.state = "off"
  return out
}

// 1234 -> "1,234"
function group(n) {
  n = Number(n) || 0
  var s = String(Math.round(n))
  var out = ""
  var c = 0
  for (var i = s.length - 1; i >= 0; i--) {
    out = s[i] + out
    if (++c % 3 === 0 && i > 0) out = "," + out
  }
  return out
}

// 1234 -> "1.2k", 1500000 -> "1.5M"
function human(n) {
  n = Number(n) || 0
  if (n >= 1e6) return trim1(n / 1e6) + "M"
  if (n >= 1e3) return trim1(n / 1e3) + "k"
  return String(Math.round(n))
}

function trim1(x) {
  return x.toFixed(1).replace(/\.0$/, "")
}

// tok/s formatting; negative or NaN reads as unavailable.
function tps(x) {
  x = Number(x)
  if (!isFinite(x) || x < 0) return "—"
  if (x >= 100) return String(Math.round(x)) + " tok/s"
  return x.toFixed(1) + " tok/s"
}

function watts(x) {
  x = Number(x)
  if (!isFinite(x) || x <= 0) return "—"
  return String(Math.round(x)) + " W"
}

// Container start epoch (seconds) -> "3h 12m" style uptime.
function uptime(epochSec) {
  var e = Number(epochSec) || 0
  if (e <= 0) return "—"
  var s = Math.max(0, Math.floor(Date.now() / 1000 - e))
  var d = Math.floor(s / 86400); s -= d * 86400
  var h = Math.floor(s / 3600); s -= h * 3600
  var m = Math.floor(s / 60); s -= m * 60
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m " + s + "s"
  return s + "s"
}

function modelName(info) {
  if (info && info.model_name) return info.model_name
  if (info && info.model_id) return info.model_id
  return "Qwen 3.8 27B"
}

function contextLabel(info) {
  var c = Number(info && info.context_window) || 0
  if (c <= 0) return "—"
  return group(c) + " tok"
}

// "rk4v4-e8" -> "RK4V4 E8"
function kvLabel(info) {
  var k = String((info && info.kv_dtype) || "")
  if (!k) return "—"
  return k.toUpperCase().replace(/-/g, " ")
}

function specLabel(info) {
  var s = String((info && info.spec) || "")
  var d = Number((info && info.draft_tokens) || 0)
  if (!s) return "Off"
  return s.toUpperCase() + (d > 0 ? " · " + d + " draft" : "")
}

// "on"/"off" vision flag from the info feed -> "On"/"Off" (unknown reads off).
function visionLabel(info) {
  return info && info.vision === "on" ? "On" : "Off"
}

// "RTX 4090 · 21.4/24.0 GB"
function gpuLabel(info) {
  if (!info) return "—"
  var name = (info.gpu_name && info.gpu_name !== "GPU") ? info.gpu_name : "GPU"
  var used = Number(info.vram_used) || 0
  var total = Number(info.vram_total) || 0
  if (used > 0 && total > 0)
    return name + " · " + trim1(used / 1024) + "/" + trim1(total / 1024) + " GB"
  return name
}

// Prefix-cache hit rate: fraction of all prompt tokens served from cache
// (hit tokens accumulate across restarts while prompt tokens reset, so the
// denominator is hit+prompt, not prompt alone).
function prefixHitLabel(info) {
  var hit = Number((info && info.prefix_hit_tokens) || 0)
  var prompt = Number((info && info.prompt_tokens) || 0)
  if (hit + prompt <= 0) return "—"
  return Math.min(100, Math.round(hit / (hit + prompt) * 100)) + "%"
}

function specAcceptLabel(info) {
  var acc = Number((info && info.draft_accepted) || 0)
  var tot = Number((info && info.draft_total) || 0)
  if (tot <= 0) return "—"
  return Math.round(acc / tot * 100) + "% accepted"
}

function requestsLabel(info) {
  var proc = Number((info && info.requests_processing) || 0)
  var def = Number((info && info.requests_deferred) || 0)
  if (proc === 0 && def === 0) return "Idle"
  var s = group(proc) + " in flight"
  if (def > 0) s += " · " + group(def) + " deferred"
  return s
}

function generatedLabel(info) {
  var n = Number((info && info.predicted_tokens) || 0)
  if (n <= 0) return "—"
  return human(n) + " tokens"
}

function contLabel(info) {
  var n = Number((info && info.cont_restored_tokens) || 0)
  if (n <= 0) return "None yet"
  return human(n) + " tokens"
}

// L1/L2/L3 restored-token fractions for the stacked cache bar.
// Fractions collapse to zero when nothing has been restored.
function cacheParts(info) {
  var l1 = Number((info && info.cont_l1_tokens) || 0)
  var l2 = Number((info && info.cont_l2_tokens) || 0)
  var l3 = Number((info && info.cont_l3_tokens) || 0)
  var total = l1 + l2 + l3
  var base = total > 0 ? total : 1
  return {
    l1: l1 / base,
    l2: l2 / base,
    l3: l3 / base,
    total: total,
    rawL1: l1,
    rawL2: l2,
    rawL3: l3
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseInfo: parseInfo,
    group: group,
    human: human,
    tps: tps,
    watts: watts,
    uptime: uptime,
    modelName: modelName,
    contextLabel: contextLabel,
    kvLabel: kvLabel,
    specLabel: specLabel,
    visionLabel: visionLabel,
    gpuLabel: gpuLabel,
    prefixHitLabel: prefixHitLabel,
    specAcceptLabel: specAcceptLabel,
    requestsLabel: requestsLabel,
    generatedLabel: generatedLabel,
    contLabel: contLabel,
    cacheParts: cacheParts
  }
}