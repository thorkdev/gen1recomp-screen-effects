-- Screen Effects: CRT scanlines, a corner vignette, mild edge chromatic
-- aberration and animated film grain, folded over the finished frame.
--
-- Registered as a `present`-stage render pipeline only -- no drawWorld, no
-- worldPresent. `present` runs after the world is decided (flat 2D, TILT,
-- or a world-owning pipeline like dramatic-shape / BATTLE_ART_VOXEL_FORK's
-- voxel diorama) and folds over the whole composite, menus and battles
-- included, the same way TILT and a world pipeline already compose today
-- (docs/modding.md, "rendering pipelines"). That is what makes this mod a
-- plain add-on: it never touches drawWorld, so it can never contend for the
-- world pass, never trips the engine's one-world-pipeline exclusion, and
-- never needs a `conflicts` entry against either voxel mod.
--
-- The SCREEN FX row and its OFF/LIGHT/HEAVY ladder are engine plumbing,
-- driven by the render_pipelines record below -- the ladder sets overall
-- strength. FILM GRAIN and SCANLINES are this mod's own OPTIONS rows, each
-- an independent on/off so a player who wants the CRT curve without the
-- grain (or the grain without the scanlines) can have it; both persist in
-- mod.save, default ON.

local LEVELS = { "OFF", "LIGHT", "HEAVY" }
local INTENSITY = { [1] = 0.5, [2] = 1.0 }

local SHADER = [[
  uniform float time;
  uniform float intensity;
  uniform float grainAmt;
  uniform float scanlineAmt;
  uniform float linePeriod;

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 px = Texel(tex, tc);

    // vignette: darken toward the corners
    vec2 d = tc - vec2(0.5);
    float vig = 1.0 - dot(d, d) * (1.1 * intensity);
    px.rgb *= clamp(vig, 0.0, 1.0);

    // mild chromatic aberration, worst at the edges -- capped well under a
    // full channel swap, which is what read as a pink/magenta fringe on
    // high-contrast Game Boy art (red pulled one way, blue the other, green
    // left alone)
    vec2 off = d * (0.0025 * intensity);
    float ca = intensity * 0.3;
    px.r = mix(px.r, Texel(tex, tc + off).r, ca);
    px.b = mix(px.b, Texel(tex, tc - off).b, ca);

    // scanlines: darken every other virtual-pixel row
    float band = mod(sc.y, linePeriod);
    float scan = 1.0 - scanlineAmt * 0.35 * step(linePeriod * 0.5, band);
    px.rgb *= scan;

    // animated grain
    float n = fract(sin(dot(sc + time * 97.13, vec2(12.9898, 78.233))) * 43758.5453);
    px.rgb += (n - 0.5) * grainAmt * 0.12;

    return px * color;
  }
]]

-- nil = untried, false = unavailable (no shader support -- headless, or a
-- driver that refuses pixel shaders); anything else is the compiled shader
local shader = nil
local canvas, cw, ch = nil, 0, 0
local elapsed = 0
local currentLevel = 0

local function getShader()
  if shader == nil then
    local ok, sh = pcall(love.graphics.newShader, SHADER)
    shader = (ok and sh) or false
  end
  return shader or nil
end

local function getCanvas(w, h)
  if not canvas or cw ~= w or ch ~= h then
    local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
    if not ok then return nil end
    canvas, cw, ch = c, w, h
  end
  return canvas
end

-- Run the pass over `input` and return the processed canvas. Returns the
-- input unchanged when the level is 0 or the shader/canvas are unavailable,
-- so a headless run or a driver with no shader support is byte-for-byte
-- what it always was -- the same safe-by-default rule TiltShift follows.
local function apply(input, scale, grainOn, scanlinesOn)
  local strength = INTENSITY[currentLevel]
  if not (strength and input) then return input end
  local sh = getShader()
  if not sh then return input end
  local w, h = input:getDimensions()
  local target = getCanvas(w, h)
  if not target then return input end

  local grainAmt = grainOn and strength or 0
  local scanlineAmt = scanlinesOn and strength or 0
  local linePeriod = math.max(1, scale or 1) * 2

  local prevBlend, prevAlpha = love.graphics.getBlendMode()
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  -- replace, not alpha-blend: this is an image-processing copy
  love.graphics.setBlendMode("replace", "premultiplied")
  pcall(sh.send, sh, "time", elapsed)
  pcall(sh.send, sh, "intensity", strength)
  pcall(sh.send, sh, "grainAmt", grainAmt)
  pcall(sh.send, sh, "scanlineAmt", scanlineAmt)
  pcall(sh.send, sh, "linePeriod", linePeriod)

  local ok = pcall(function()
    love.graphics.setCanvas(target)
    love.graphics.draw(input)
  end)

  love.graphics.setCanvas()
  love.graphics.setShader()
  love.graphics.setBlendMode(prevBlend or "alpha", prevAlpha)
  return ok and target or input
end

return function(mod)
  mod.content.render_pipelines:register("screen_fx", {
    label = "SCREEN FX",
    levels = LEVELS,
    priority = 10,

    -- presentational tween source: the engine hands over this pipeline's
    -- level every frame regardless of whether it is on, exactly like
    -- TiltShift reads its own level (dramatic-shape/lib/TiltShift.lua)
    update = function(dt, level)
      currentLevel = level or 0
      if currentLevel > 0 then elapsed = elapsed + dt end
    end,

    -- present, not worldPresent: a CRT curve belongs on the whole frame,
    -- menus and battles included, not just the world underneath them.
    present = function(inCanvas, ctx)
      return apply(inCanvas, ctx and ctx.scale,
        mod.save:get("grain", true), mod.save:get("scanlines", true))
    end,

    invalidate = function()
      canvas, cw, ch = nil, 0, 0
    end,
  })

  local grainRow = {
    id = "screen_fx_grain",
    label = "FILM GRAIN",
    value = function()
      return mod.save:get("grain", true) and "ON" or "OFF"
    end,
    step = function()
      mod.save:set("grain", not mod.save:get("grain", true))
      return true
    end,
  }
  local scanlinesRow = {
    id = "screen_fx_scanlines",
    label = "SCANLINES",
    value = function()
      return mod.save:get("scanlines", true) and "ON" or "OFF"
    end,
    step = function()
      mod.save:set("scanlines", not mod.save:get("scanlines", true))
      return true
    end,
  }

  mod.hooks:wrap("ui.options.rows", function(next, game, rows)
    local out = next(game, rows)
    if type(out) ~= "table" then return out end
    -- the engine already spliced the SCREEN FX ladder in as "pipeline:
    -- screen_fx" (Pipelines.rows, next to TILT); slot FILM GRAIN and
    -- SCANLINES right after it so all three sit together instead of the
    -- ladder up top and the toggles at the very bottom of the menu
    local merged = {}
    for _, row in ipairs(out) do
      merged[#merged + 1] = row
      if row.id == "pipeline:screen_fx" then
        merged[#merged + 1] = grainRow
        merged[#merged + 1] = scanlinesRow
      end
    end
    -- the pipeline row was somehow not found (a future engine change): fall
    -- back to appending rather than silently dropping the two rows
    if #merged == #out then
      merged[#merged + 1] = grainRow
      merged[#merged + 1] = scanlinesRow
    end
    return merged
  end)
end